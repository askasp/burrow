defmodule Burrow.Chats do
  @moduledoc """
  Chats with the agent, a project's tabs. The conversation lives in the
  chat's opencode session (`Burrow.Chat`); Burrow keeps the chat's title,
  session, model and keep-running time, or for a repo chat its pull request.
  A chat's change is its draft in the project's history, under the chat's id.

  A project has at most four chats (`max/0`). A chat starts empty (title
  `""`) and its first message titles it (`started/2`).

  Broadcasts `{:chat_created, chat}`, `{:chat_started, id}` and
  `{:chat_deleted, id}` on the project's `"chats"` topic; `Burrow.Chat`
  broadcasts `{:chat_busy, id, busy?}` there.
  """

  import Ecto.Query

  alias Burrow.{Projects, Repo}
  alias Burrow.Chats.Chat

  @efforts ~w(low medium high)
  @max 4

  def efforts, do: @efforts
  def max, do: @max

  def subscribe(project_id), do: Projects.subscribe(project_id, "chats")

  def room?(project_id),
    do: Repo.aggregate(from(c in Chat, where: c.project_id == ^project_id), :count) < @max

  def create_empty(project_id, created_by) do
    if room?(project_id),
      do: {:ok, create(project_id, "", created_by, started: false)},
      else: {:error, :full}
  end

  @doc "Creates a chat. Options: `:model` (provider/model), `:effort`, `started: false`."
  def create(project_id, title, created_by, opts \\ []) do
    model =
      if is_binary(opts[:model]) and opts[:model] =~ ~r"\A[\w.-]+/[\w.:-]+\z", do: opts[:model]

    chat =
      Repo.insert!(%Chat{
        id: :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false),
        project_id: project_id,
        title: title |> String.trim() |> String.slice(0, 80),
        created_by: created_by,
        model: model,
        effort: if(opts[:effort] in @efforts, do: opts[:effort]),
        started_at: if(opts[:started] != false, do: DateTime.utc_now(:second))
      })

    Projects.broadcast(project_id, "chats", {:chat_created, chat})
    chat
  end

  @doc "The chat got its first message: an empty chat takes its title from it."
  def started(%Chat{} = chat, text) do
    title = text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
    query = from c in Chat, where: c.id == ^chat.id

    Repo.update_all(where(query, [c], is_nil(c.started_at)),
      set: [started_at: DateTime.utc_now(:second)]
    )

    Repo.update_all(where(query, [c], c.title == ""), set: [title: title])
    Projects.broadcast(chat.project_id, "chats", {:chat_started, chat.id})
  end

  @doc "A project's chats, oldest first: the order of the tabs."
  def list(project_id),
    do:
      Repo.all(
        from c in Chat,
          where: c.project_id == ^project_id,
          order_by: [asc: c.inserted_at, asc: c.id]
      )

  def get(id), do: Repo.get(Chat, id)

  def set(%Chat{id: id}, fields),
    do: Repo.update_all(from(c in Chat, where: c.id == ^id), set: fields)

  @doc "Keeps the chat running for `hours` from now; nil goes back to the idle stop."
  def keep_running(%Chat{} = chat, hours) do
    until = if hours, do: DateTime.utc_now(:second) |> DateTime.add(hours, :hour)
    set(chat, keep_until: until)
    until
  end

  def kept_running?(%Chat{keep_until: until}),
    do: until != nil and DateTime.after?(until, DateTime.utc_now())

  def kept_running?(nil), do: false

  def list_kept_running(project_id), do: Enum.filter(list(project_id), &kept_running?/1)

  def delete(%Chat{} = chat) do
    Repo.delete_all(from c in Chat, where: c.id == ^chat.id)
    Projects.broadcast(chat.project_id, "chats", {:chat_deleted, chat.id})
  end
end
