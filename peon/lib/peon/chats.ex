defmodule Peon.Chats do
  @moduledoc """
  Chats with the AI. The conversation itself lives in an opencode session
  (see `Peon.Chat`); Peon stores only the chat's title, its session id and
  the changesets it produced (`changesets.conversation_id`), or for a repo
  chat its pull request.

  A project has at most four chats (`max/0`), each one changeset. A chat can be
  created empty, with no title (`""`), and waits for its first message,
  which titles it (`started/2`). A new project starts with one.

  Broadcasts `{:chat_created, chat}`, `{:chat_started, id}` and
  `{:chat_deleted, id}` on topic `"chats"`, and `Peon.Chat` broadcasts
  `{:chat_busy, id, busy?}` there.
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
      # The agent's model (provider/model) and effort; nil for the defaults.
      field :model, :string
      field :effort, :string
      # A repo chat's pull request (`Peon.PullRequest`).
      field :pr_url, :string
      # The chat keeps running without use until then (`Peon.Chat`).
      field :keep_until, :utc_datetime
      # When its first message went in; nil while the chat is empty.
      field :started_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Peon.PubSub, "chats")

  @efforts ~w(low medium high)
  @max 4

  def efforts, do: @efforts

  @doc "How many chats a project can have open at once."
  def max, do: @max

  @doc "Whether there is room for another chat (`max/0`)."
  def room?, do: Repo.aggregate(Chat, :count) < @max

  @doc "Creates an empty chat, for its first message to title, when there is room."
  def create_empty(created_by) do
    if room?(), do: {:ok, create("", created_by, started: false)}, else: {:error, :full}
  end

  @doc """
  The first chat of a new project, once: empty, waiting for what the app
  should do.
  """
  def create_first do
    if Peon.Project.settings()["first_chat"] == nil do
      Peon.Project.put_settings(%{"first_chat" => true})
      if list() == [], do: create("", "peon", started: false)
    end

    :ok
  end

  @doc """
  The chat got its first message: an empty chat takes its title from it.
  """
  def started(id, text) do
    now = DateTime.utc_now(:second)
    title = text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)

    Repo.update_all(from(c in Chat, where: c.id == ^id and is_nil(c.started_at)),
      set: [started_at: now]
    )

    Repo.update_all(from(c in Chat, where: c.id == ^id and c.title == ""), set: [title: title])
    Phoenix.PubSub.broadcast(Peon.PubSub, "chats", {:chat_started, id})
  end

  @doc """
  Creates a chat. Options: `:model` (provider/model), `:effort`
  (#{Enum.join(@efforts, ", ")}), and `started: false` for an empty one.
  """
  def create(title, created_by, opts \\ []) do
    id = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
    title = title |> String.trim() |> String.slice(0, 80)

    model =
      if is_binary(opts[:model]) and opts[:model] =~ ~r"\A[\w.-]+/[\w.:-]+\z", do: opts[:model]

    effort = if opts[:effort] in @efforts, do: opts[:effort]

    chat =
      Repo.insert!(%Chat{
        id: id,
        title: title,
        created_by: created_by,
        model: model,
        effort: effort,
        started_at: if(opts[:started] != false, do: DateTime.utc_now(:second))
      })

    Phoenix.PubSub.broadcast(Peon.PubSub, "chats", {:chat_created, chat})
    chat
  end

  @doc "The chats, oldest first: the order of the workspace's tabs."
  def list, do: Repo.all(from c in Chat, order_by: [asc: c.inserted_at, asc: c.id])

  def get(id), do: Repo.get(Chat, id)

  def set_session(id, session_id) do
    Repo.update_all(from(c in Chat, where: c.id == ^id), set: [session_id: session_id])
  end

  @doc "Keeps the chat running for `hours` from now; nil goes back to the idle stop."
  def keep_running(id, hours) do
    until =
      if hours, do: DateTime.utc_now() |> DateTime.add(hours, :hour) |> DateTime.truncate(:second)

    Repo.update_all(from(c in Chat, where: c.id == ^id), set: [keep_until: until])
    until
  end

  def kept_running?(%Chat{keep_until: until}),
    do: until != nil and DateTime.after?(until, DateTime.utc_now())

  def kept_running?(nil), do: false

  def list_kept_running, do: Enum.filter(list(), &kept_running?/1)

  @doc "Deletes the chat's row; `Peon.Chat.delete/1` also stops it and removes its files."
  def delete(id) do
    Repo.delete_all(from c in Chat, where: c.id == ^id)
    Phoenix.PubSub.broadcast(Peon.PubSub, "chats", {:chat_deleted, id})
  end

  def set_pr_url(id, url) do
    Repo.update_all(from(c in Chat, where: c.id == ^id), set: [pr_url: url])
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
