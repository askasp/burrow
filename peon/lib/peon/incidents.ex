defmodule Peon.Incidents do
  @moduledoc """
  Errors from running environments, grouped by fingerprint (exception and
  the app frame it came from). A new or recurring incident opens a chat that
  is asked to fix it (project setting `"auto_fix"`, default on, at most
  three chats at a time); otherwise the user starts one from the UI. An
  incident is resolved when a changeset from its chat is deployed to the
  environment it came from.

  Broadcasts `{:incident, incident}` on topic `"incidents"`.
  """

  import Ecto.Query

  alias Peon.{Chats, Code, Project, Repo, Ship}
  alias Peon.Incidents.Incident
  alias Peon.Store.Changeset

  @max_fixing 3

  def subscribe, do: Phoenix.PubSub.subscribe(Peon.PubSub, "incidents")

  def list(limit \\ 20),
    do: Repo.all(from i in Incident, order_by: [desc: i.last_seen_at, desc: i.id], limit: ^limit)

  def get(id), do: Repo.get(Incident, id)

  @doc """
  Groups an error event (from the attacher, see `priv/attacher.exs`) or a
  failed deploy (`"fingerprint"` given) into an incident.
  """
  def report(env, event, deployed_id) do
    fingerprint = fingerprint(event)
    now = DateTime.utc_now(:second)

    case Repo.get_by(Incident, env: env, fingerprint: fingerprint) do
      nil ->
        %Incident{
          env: env,
          fingerprint: fingerprint,
          title: title(event),
          detail: detail(event),
          status: "open",
          changeset_id: deployed_id,
          last_seen_at: now
        }
        |> Repo.insert!()
        |> broadcast()
        |> maybe_fix()

      %{status: "resolved"} = incident ->
        incident
        |> Ecto.Changeset.change(
          count: incident.count + 1,
          status: "open",
          chat_id: nil,
          detail: detail(event),
          changeset_id: deployed_id,
          last_seen_at: now
        )
        |> Repo.update!()
        |> broadcast()
        |> maybe_fix()

      incident ->
        incident
        |> Ecto.Changeset.change(count: incident.count + 1, last_seen_at: now)
        |> Repo.update!()
        |> broadcast()
    end
  end

  @doc "Opens a chat that is asked to fix the incident."
  def fix(%Incident{} = incident, created_by \\ "peon") do
    chat = Chats.create("Fix: " <> incident.title, created_by)

    incident =
      incident
      |> Ecto.Changeset.change(status: "fixing", chat_id: chat.id)
      |> Repo.update!()
      |> broadcast()

    Ship.tell_chat(chat.id, prompt(incident))
    incident
  end

  @doc """
  The fix chat stopped with an error (provider hiccup, no AI login...). It is
  asked once more right away (`:fix_retries`, default 1); after that the
  incident goes back to open with the reason and the chat link, for the user.
  """
  def chat_failed(chat_id, reason) do
    retries = Application.get_env(:peon, :fix_retries, 1)

    for incident <-
          Repo.all(from i in Incident, where: i.chat_id == ^chat_id and i.status == "fixing") do
      tries = length(String.split(incident.detail, "Fix chat stopped")) - 1
      retry? = tries < retries
      note = if retry?, do: " (asked again)", else: ""

      incident =
        incident
        |> Ecto.Changeset.change(
          status: if(retry?, do: "fixing", else: "open"),
          detail: "Fix chat stopped#{note}: #{reason}\n\n" <> incident.detail
        )
        |> Repo.update!()
        |> broadcast()

      if retry?,
        do:
          Ship.tell_chat(
            chat_id,
            "The last attempt stopped (#{reason}). Try again.\n\n" <> prompt(incident)
          )
    end

    :ok
  end

  def resolve(%Incident{} = incident),
    do: incident |> Ecto.Changeset.change(status: "resolved") |> Repo.update!() |> broadcast()

  @doc "Resolves incidents in `env` whose fix is part of the deployed changeset."
  def deployed(env, changeset_id) do
    fixing =
      Repo.all(
        from i in Incident,
          where: i.env == ^env and i.status == "fixing" and not is_nil(i.chat_id)
      )

    for incident <- fixing, fixed_in?(incident.chat_id, changeset_id), do: resolve(incident)
    :ok
  end

  defp fixed_in?(chat_id, deployed_id) do
    Repo.all(from c in Changeset, where: c.conversation_id == ^chat_id, select: c.id)
    |> Enum.any?(&Code.ancestor?(&1, deployed_id))
  end

  @doc "What makes two errors the same incident: kind plus app frame, or the normalized message."
  def fingerprint(%{"fingerprint" => fingerprint}) when is_binary(fingerprint), do: fingerprint

  def fingerprint(event) do
    where = event["frame"] || normalize(event["message"] || "")

    :crypto.hash(:sha256, "#{event["kind"]}|#{where}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp normalize(message) do
    message
    |> String.replace(~r/#(PID|Reference|Port)<[\d.]+>|0x[0-9a-f]+|\d+/, "_")
    |> String.slice(0, 200)
  end

  defp title(event) do
    # One line: Erlang's argument errors put the useful part on the second line.
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

  defp maybe_fix(incident) do
    fixing = Repo.aggregate(from(i in Incident, where: i.status == "fixing"), :count)

    if Project.settings()["auto_fix"] != false and fixing < @max_fixing,
      do: fix(incident),
      else: incident
  end

  defp prompt(incident) do
    deployed = if incident.changeset_id, do: " with changeset ##{incident.changeset_id}", else: ""

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
    Phoenix.PubSub.broadcast(Peon.PubSub, "incidents", {:incident, incident})
    incident
  end
end
