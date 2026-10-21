defmodule Burrow.Incidents do
  @moduledoc """
  Errors from a project's running environments, grouped by fingerprint
  (Totem gives each error one), and failed deploys. A new or recurring
  incident opens a chat asked to fix it (setting `"auto_fix"`, default on,
  at most three at a time, while the project has room for a chat). An
  incident resolves when its chat's change is deployed where it came from.

  Broadcasts `{:incident, incident}` on the project's `"incidents"` topic.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Burrow.{Chats, Projects, Repo, Ship}

  schema "incidents" do
    field :project_id, :integer
    field :env, :string
    field :fingerprint, :string
    field :title, :string
    field :detail, :string
    # open, fixing, resolved
    field :status, :string, default: "open"
    field :count, :integer, default: 1
    field :chat_id, :string
    # The change that was deployed when it happened
    field :change_id, :integer
    field :last_seen_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @max_fixing 3

  def subscribe(project_id), do: Projects.subscribe(project_id, "incidents")

  def list(project_id, limit \\ 20),
    do: Repo.all(from i in __MODULE__, where: i.project_id == ^project_id, order_by: [desc: i.last_seen_at, desc: i.id], limit: ^limit)

  def get(id), do: Repo.get(__MODULE__, id)

  @doc "Groups an error event (with its `\"fingerprint\"`) into an incident of `project`'s `env`."
  def report(project, env, event, change_id) do
    now = DateTime.utc_now(:second)
    fingerprint = event["fingerprint"] || "#{event["kind"]}|#{event["message"]}"

    case Repo.get_by(__MODULE__, project_id: project.id, env: env, fingerprint: fingerprint) do
      nil ->
        %__MODULE__{project_id: project.id, env: env, fingerprint: fingerprint, title: title(event),
                    detail: detail(event), change_id: change_id, last_seen_at: now}
        |> Repo.insert!()
        |> broadcast()
        |> maybe_fix(project)

      %{status: "resolved"} = incident ->
        incident
        |> Ecto.Changeset.change(count: incident.count + 1, status: "open", chat_id: nil,
          detail: detail(event), change_id: change_id, last_seen_at: now)
        |> Repo.update!()
        |> broadcast()
        |> maybe_fix(project)

      incident ->
        incident |> Ecto.Changeset.change(count: incident.count + 1, last_seen_at: now) |> Repo.update!() |> broadcast()
    end
  end

  @doc "Opens a chat asked to fix the incident, when there is room for one."
  def fix(%__MODULE__{} = incident, project, created_by \\ "peon") do
    if Chats.room?(project.id) do
      chat = Chats.create(project.id, "Fix: " <> incident.title, created_by)
      incident = incident |> Ecto.Changeset.change(status: "fixing", chat_id: chat.id) |> Repo.update!() |> broadcast()
      Ship.tell_chat(project.id, chat.id, prompt(incident))
      {:ok, incident}
    else
      {:error, :full}
    end
  end

  @doc """
  The fix chat stopped with an error. It is asked once more (`:fix_retries`,
  default 1); after that the incident goes back to open, for the user.
  """
  def chat_failed(project_id, chat_id, reason) do
    retries = Application.get_env(:burrow, :fix_retries, 1)

    for incident <- fixing(project_id, chat_id) do
      retry? = length(String.split(incident.detail, "Fix chat stopped")) - 1 < retries

      incident =
        incident
        |> Ecto.Changeset.change(status: if(retry?, do: "fixing", else: "open"),
          detail: "Fix chat stopped#{if retry?, do: " (asked again)"}: #{reason}\n\n" <> incident.detail)
        |> Repo.update!()
        |> broadcast()

      if retry?, do: Ship.tell_chat(project_id, chat_id, "The last attempt stopped (#{reason}). Try again.\n\n" <> prompt(incident))
    end

    :ok
  end

  def chat_deleted(project_id, chat_id) do
    for incident <- fixing(project_id, chat_id),
        do: incident |> Ecto.Changeset.change(status: "open", chat_id: nil) |> Repo.update!() |> broadcast()

    :ok
  end

  def resolve(%__MODULE__{} = incident),
    do: incident |> Ecto.Changeset.change(status: "resolved") |> Repo.update!() |> broadcast()

  @doc "Resolves `env`'s incidents whose fix is part of deployed change `change_id`."
  def deployed(project, env, change_id) do
    dir = Projects.repo_dir(project)

    for i <- Repo.all(from i in __MODULE__, where: i.project_id == ^project.id and i.env == ^env and i.status == "fixing"),
        draft = Totem.Repo.draft(dir, i.chat_id),
        draft && draft.change && draft.change <= change_id,
        do: resolve(i)

    :ok
  end

  defp fixing(project_id, chat_id),
    do: Repo.all(from i in __MODULE__, where: i.project_id == ^project_id and i.chat_id == ^chat_id and i.status == "fixing")

  defp title(event) do
    message = event["message"] |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    text = if event["kind"] in [nil, "deploy"], do: message, else: "#{event["kind"]}: #{message}"
    text = if event["frame"], do: "#{text} (#{event["frame"]})", else: text
    String.slice(text, 0, 160)
  end

  defp detail(event) do
    text = event["text"] || ""
    stack = event["stacktrace"] || ""

    if stack == "" or String.contains?(text, String.slice(String.trim(stack), 0, 60)),
      do: text,
      else: text <> "\n\n" <> stack
  end

  defp maybe_fix(incident, project) do
    fixing = Repo.aggregate(from(i in __MODULE__, where: i.project_id == ^project.id and i.status == "fixing"), :count)

    with true <- Projects.settings(project)["auto_fix"] != false and fixing < @max_fixing,
         {:ok, incident} <- fix(incident, project) do
      incident
    else
      _ -> incident
    end
  end

  defp prompt(incident) do
    deployed = if incident.change_id, do: " with change ##{incident.change_id}", else: ""

    """
    The #{incident.env} app reported this problem#{deployed} deployed \
    (#{incident.count} time(s) so far):

    #{incident.title}

    #{incident.detail}

    Find the cause, reproduce it with a test, fix it and submit. The peon_runtime tool \
    shows the running #{incident.env} app (status, recent errors, top processes).\
    """
  end

  defp broadcast(incident) do
    Projects.broadcast(incident.project_id, "incidents", {:incident, incident})
    incident
  end
end
