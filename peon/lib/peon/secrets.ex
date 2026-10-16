defmodule Peon.Secrets do
  @moduledoc """
  The project's secrets: API keys, tokens and passwords that the app reads as
  environment variables, so they never go into its code. People set them in
  Peon; the agent only sees their names, and can ask for one it needs
  (`request/3`), which shows up in its chat for the user to fill in.

  The preview, staging and prod get every set secret as an environment
  variable. Checks and the agent's own shell don't: tests use fakes.

  Broadcasts `{:secrets, list}` on topic `"secrets"` after every change; envs
  and chats restart their containers to pick up new values.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Peon.{Repo, Ship}

  @primary_key {:name, :string, autogenerate: false}
  schema "secrets" do
    field :value, :binary, redact: true
    field :why, :string
    field :chat_id, :string
    field :set_by, :string
    timestamps(type: :utc_datetime)
  end

  @name ~r/\A[A-Z][A-Z0-9_]{1,63}\z/
  # Set by Peon itself for the app's containers.
  @reserved ~w(MIX_ENV PORT PHX_HOST PHX_SERVER SECRET_KEY_BASE DATABASE_PATH DATABASE_URL
               PREVIEW_BIND HOME PATH LANG RELEASE_COOKIE)

  def subscribe, do: Phoenix.PubSub.subscribe(Peon.PubSub, "secrets")

  @doc """
  Every secret without its value, by name:
  `%{name, set?, why, chat_id, set_by, updated_at}`.
  """
  def list do
    Repo.all(from s in __MODULE__, order_by: s.name)
    |> Enum.map(&public/1)
  end

  @doc "Names the agent has asked for that nobody has set yet."
  def requested(chat_id \\ nil) do
    query = from s in __MODULE__, where: is_nil(s.value), order_by: s.name
    query = if chat_id, do: where(query, [s], s.chat_id == ^chat_id), else: query
    Repo.all(query) |> Enum.map(&public/1)
  end

  @doc "The environment variables for the app's containers: every set secret."
  def env do
    Repo.all(from s in __MODULE__, where: not is_nil(s.value), select: {s.name, s.value})
    |> Map.new()
  end

  @doc "A short hash of `env/0`, to tell whether a container has the current values."
  def fingerprint(env \\ env()) do
    env
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  @doc "Sets (or replaces) a secret. Tells the chat that asked for it, if any."
  def put(name, value, set_by) do
    with :ok <- validate_name(name),
         :ok <- validate_value(value) do
      existing = Repo.get(__MODULE__, name)

      (existing || %__MODULE__{name: name})
      |> Ecto.Changeset.change(value: value, set_by: set_by)
      |> Repo.insert_or_update!()

      broadcast()

      if existing && existing.value == nil && existing.chat_id,
        do: notify(existing.chat_id, name)

      :ok
    end
  end

  @doc "The agent asks for a secret. Returns `{:ok, :requested | :already_set}`."
  def request(name, why, chat_id) do
    with :ok <- validate_name(name) do
      case Repo.get(__MODULE__, name) do
        %{value: value} when value != nil ->
          {:ok, :already_set}

        existing ->
          (existing || %__MODULE__{name: name})
          |> Ecto.Changeset.change(why: why, chat_id: chat_id)
          |> Repo.insert_or_update!()

          broadcast()
          {:ok, :requested}
      end
    end
  end

  def delete(name) do
    case Repo.get(__MODULE__, name) do
      nil -> :ok
      secret -> Repo.delete!(secret) && broadcast()
    end

    :ok
  end

  def validate_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@name, name) ->
        {:error, "Use capital letters, digits and _ (like SLACK_TOKEN)."}

      name in @reserved or String.starts_with?(name, ["PEON_", "RELEASE_", "ERL_"]) ->
        {:error, "#{name} is set by Peon itself."}

      true ->
        :ok
    end
  end

  def validate_name(_), do: {:error, "A name is needed."}

  defp validate_value(value) when is_binary(value) and value != "" do
    if byte_size(value) <= 32_768 and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, "That value is too long or holds a NUL byte."}
  end

  defp validate_value(_), do: {:error, "A value is needed."}

  defp public(secret) do
    %{
      name: secret.name,
      set?: secret.value != nil,
      why: secret.why,
      chat_id: secret.chat_id,
      set_by: secret.set_by,
      updated_at: secret.updated_at
    }
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(Peon.PubSub, "secrets", {:secrets, list()})
  end

  # Wakes the chat that asked, so the agent carries on.
  defp notify(chat_id, name) do
    Ship.tell_chat(
      chat_id,
      "The user set #{name}. The preview, staging and prod now have it as an environment " <>
        "variable (they restart to pick it up). Carry on."
    )
  end
end
