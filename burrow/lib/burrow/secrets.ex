defmodule Burrow.Secrets do
  @moduledoc """
  A project's secrets: API keys, tokens and passwords the app reads as
  environment variables, so they never go into its code. People set them in
  the workspace; the agent only sees their names and can ask for one
  (`request/4`), which shows up in its chat for the user to fill in.

  Previews and environments get every set secret as an environment
  variable; the agent's own shell and the checks don't. `GITHUB_TOKEN` is
  Burrow's own (`Burrow.GitRepo`) and never reaches the app.

  Broadcasts `{:secrets, list}` on the project's `"secrets"` topic; previews
  and environments restart to pick up new values.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Burrow.{Projects, Repo}

  schema "secrets" do
    field :project_id, :integer
    field :name, :string
    field :value, :binary, redact: true
    field :why, :string
    field :chat_id, :string
    field :set_by, :string
    timestamps(type: :utc_datetime)
  end

  @name ~r/\A[A-Z][A-Z0-9_]{1,63}\z/
  @reserved ~w(MIX_ENV PORT PHX_HOST PHX_SERVER SECRET_KEY_BASE DATABASE_PATH DATABASE_URL
               PREVIEW_BIND HOME PATH LANG RELEASE_COOKIE)
  @burrow_only ~w(GITHUB_TOKEN)

  def subscribe(project_id), do: Projects.subscribe(project_id, "secrets")

  @doc "Every secret without its value: `%{name, set?, why, chat_id, set_by, updated_at}`."
  def list(project_id) do
    Repo.all(from s in __MODULE__, where: s.project_id == ^project_id, order_by: s.name)
    |> Enum.map(&public/1)
  end

  @doc "The app's environment variables: every set secret."
  def env(project_id) do
    Repo.all(
      from s in __MODULE__,
        where: s.project_id == ^project_id and not is_nil(s.value) and s.name not in @burrow_only,
        select: {s.name, s.value}
    )
    |> Map.new()
  end

  def value(project_id, name) do
    Repo.one(
      from s in __MODULE__,
        where: s.project_id == ^project_id and s.name == ^name and not is_nil(s.value),
        select: s.value
    )
  end

  @doc "A short hash of `env/1`, to tell whether a container has the current values."
  def fingerprint(env) do
    env |> Enum.sort() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false) |> binary_part(0, 16)
  end

  @doc "Sets (or replaces) a secret, and tells the chat that asked for it."
  def put(project_id, name, value, set_by) do
    with :ok <- validate_name(name), :ok <- validate_value(value) do
      existing = get(project_id, name)

      (existing || %__MODULE__{project_id: project_id, name: name})
      |> Ecto.Changeset.change(value: value, set_by: set_by)
      |> Repo.insert_or_update!()

      broadcast(project_id)

      if existing && existing.value == nil && existing.chat_id,
        do: Burrow.Ship.tell_chat(project_id, existing.chat_id, "The user set #{name}. Carry on.")

      :ok
    end
  end

  @doc "The agent (or Burrow) asks for a secret: `{:ok, :requested | :already_set}`."
  def request(project_id, name, why, chat_id) do
    with :ok <- validate_name(name) do
      case get(project_id, name) do
        %{value: value} when value != nil ->
          {:ok, :already_set}

        existing ->
          (existing || %__MODULE__{project_id: project_id, name: name})
          |> Ecto.Changeset.change(why: why, chat_id: chat_id)
          |> Repo.insert_or_update!()

          broadcast(project_id)
          {:ok, :requested}
      end
    end
  end

  def delete(project_id, name) do
    if secret = get(project_id, name), do: Repo.delete!(secret) && broadcast(project_id)
    :ok
  end

  def validate_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@name, name) -> {:error, "Use capital letters, digits and _ (like SLACK_TOKEN)."}
      name in @reserved or String.starts_with?(name, ["PEON_", "TOTEM_", "RELEASE_", "ERL_"]) ->
        {:error, "#{name} is set by Burrow itself."}
      true -> :ok
    end
  end

  def validate_name(_), do: {:error, "A name is needed."}

  defp validate_value(value) when is_binary(value) and value != "" do
    if byte_size(value) <= 32_768 and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, "That value is too long or holds a NUL byte."}
  end

  defp validate_value(_), do: {:error, "A value is needed."}

  defp get(project_id, name), do: Repo.get_by(__MODULE__, project_id: project_id, name: name)

  defp public(s),
    do: %{name: s.name, set?: s.value != nil, why: s.why, chat_id: s.chat_id, set_by: s.set_by, updated_at: s.updated_at}

  defp broadcast(project_id), do: Projects.broadcast(project_id, "secrets", {:secrets, list(project_id)})
end
