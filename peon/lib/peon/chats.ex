defmodule Peon.Chats do
  @moduledoc """
  Chats with the AI. The conversation itself lives in an opencode session
  (see `Peon.Chat`); Peon stores only the chat's title, its session id and
  the changesets it produced (`changesets.conversation_id`).

  Broadcasts `{:chat_created, chat}` on topic `"chats"`.
  """

  import Ecto.Query

  alias Peon.Repo
  alias Peon.Store.Changeset

  defmodule Chat do
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "conversations" do
      field :title, :string
      field :created_by, :string
      field :session_id, :string
      timestamps(type: :utc_datetime)
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Peon.PubSub, "chats")

  def create(title, created_by) do
    id = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
    title = title |> String.trim() |> String.slice(0, 80)
    chat = Repo.insert!(%Chat{id: id, title: title, created_by: created_by})
    Phoenix.PubSub.broadcast(Peon.PubSub, "chats", {:chat_created, chat})
    chat
  end

  def list, do: Repo.all(from c in Chat, order_by: [desc: c.inserted_at, desc: c.id])

  def get(id), do: Repo.get(Chat, id)

  def set_session(id, session_id) do
    Repo.update_all(from(c in Chat, where: c.id == ^id), set: [session_id: session_id])
  end

  @doc "The chat's newest changeset, if any."
  def latest_changeset(id) do
    Repo.one(
      from c in Changeset,
        where: c.conversation_id == ^id,
        order_by: [desc: c.id],
        limit: 1
    )
  end

  @doc "The chat's newest changeset that is still open (not superseded, not on main)."
  def draft(id) do
    case latest_changeset(id) do
      nil ->
        nil

      %{status: "superseded"} ->
        nil

      cs ->
        main = Peon.Code.ref("main")
        if main && Peon.Code.ancestor?(cs.id, main.changeset_id), do: nil, else: cs
    end
  end
end
