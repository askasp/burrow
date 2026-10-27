defmodule Burrow.Chats do
  @moduledoc """
  Chats with the agent, a project's drawer. The conversation lives in the
  chat's opencode session (`Burrow.Chat`); Burrow keeps the chat's title,
  session, model and thinking level and keep-running time, or for a repo
  chat its pull request. A chat's change is its draft in the project's
  history, under the chat's id.

  A chat is seen only by the user who opened it; one Peon opened (an
  incident's fix, a project's first chat) by the project's owner
  (`list/2`). Done chats stay, to read and follow up on. A chat starts empty (title `""`) and its first message titles it
  (`started/2`).

  Broadcasts `{:chat_created, chat}`, `{:chat_started, id}` and
  `{:chat_deleted, id}` on the project's `"chats"` topic; `Burrow.Chat`
  broadcasts `{:chat_busy, id, busy?}` there.
  """

  import Ecto.Query

  alias Burrow.{Accounts, Projects, Repo}
  alias Burrow.Chats.Chat

  def subscribe(project_id), do: Projects.subscribe(project_id, "chats")

  def create_empty(project_id, by, opts \\ []),
    do: create(project_id, "", by, [started: false] ++ opts)

  @doc """
  Creates a chat for `by`, the user who opens it, or a name such as
  `"peon"` for one the project's owner sees. Options: `:model` and
  `:effort` (see `pick_model/3`), `:follows` (the change it follows up on),
  `:from_chat` (the general chat it starts from, `Burrow.GeneralChats`),
  `:horde_id` (the horde it is a peon of, `Burrow.Hordes`), `:shipping`
  (`Burrow.Ship`), `started: false`.
  """
  def create(project_id, title, by, opts \\ []) do
    {created_by, user_id} = by(by)

    chat =
      Repo.insert!(%Chat{
        id: :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false),
        project_id: project_id,
        title: title |> String.trim() |> String.slice(0, 80),
        created_by: created_by,
        user_id: user_id,
        model: model(opts[:model]),
        effort: effort(opts[:effort]),
        follows: opts[:follows],
        from_chat: opts[:from_chat],
        horde_id: opts[:horde_id],
        shipping: opts[:shipping],
        started_at: if(opts[:started] != false, do: DateTime.utc_now(:second))
      })

    Projects.broadcast(project_id, "chats", {:chat_created, chat})
    chat
  end

  defp by(%Accounts.User{id: id, email: email}), do: {email, id}
  defp by(name) when is_binary(name), do: {name, nil}

  @doc """
  The chat got a message: it was worked on now (`updated_at`, the drawer's
  order), and an empty chat takes its title from it.
  """
  def started(%Chat{} = chat, text) do
    title = text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
    query = from c in Chat, where: c.id == ^chat.id
    now = DateTime.utc_now(:second)

    Repo.update_all(query, set: [updated_at: now])
    Repo.update_all(where(query, [c], is_nil(c.started_at)), set: [started_at: now])

    Repo.update_all(where(query, [c], c.title == ""), set: [title: title])
    Projects.broadcast(chat.project_id, "chats", {:chat_started, chat.id})
  end

  @doc "A project's chats, oldest first."
  def list(project_id),
    do:
      Repo.all(
        from c in Chat,
          where: c.project_id == ^project_id,
          order_by: [asc: c.inserted_at, asc: c.id]
      )

  @doc """
  The project's chats user `user_id` sees, oldest first: the ones they
  opened, and for the project's owner the ones Peon opened.
  """
  def list(%Projects.Project{} = project, user_id),
    do:
      Repo.all(
        from c in Chat,
          where: c.project_id == ^project.id,
          where: ^seen_by(project, user_id),
          order_by: [asc: c.inserted_at, asc: c.id]
      )

  def get(id), do: Repo.get(Chat, id)

  @doc """
  Whether the chat is a horde's peon (`Burrow.Hordes`): it is opened from
  its horde's chat, and lists of chats leave it out.
  """
  def peon?(%Chat{horde_id: id}), do: id != nil

  @doc "The project's chat `id` when user `user_id` sees it (`list/2`), else nil."
  def get(%Projects.Project{} = project, user_id, id),
    do:
      Repo.one(
        from c in Chat,
          where: c.id == ^id and c.project_id == ^project.id,
          where: ^seen_by(project, user_id)
      )

  defp seen_by(%Projects.Project{user_id: owner_id}, owner_id),
    do: dynamic([c], c.user_id == ^owner_id or is_nil(c.user_id))

  defp seen_by(_project, user_id), do: dynamic([c], c.user_id == ^user_id)

  @doc """
  The chat's model (provider/model; nil for the owner's) and effort, one of
  the model's opencode variants (nil for its default), from its next message.
  """
  def pick_model(%Chat{} = chat, model, effort),
    do: set(chat, model: model(model), effort: effort(effort))

  @doc """
  The opencode agents a chat can talk to: Plan reads and plans, Build does
  the work, Design only draws boards (`Burrow.Design`). A repo has no
  boards, so no Design.
  """
  def agents(%Projects.Project{} = project),
    do: if(Projects.Project.repo?(project), do: ~w(plan build), else: ~w(plan build design))

  @doc "The ids of the project's chats on autopilot (`pick_shipping/2`)."
  def piloted(project_id),
    do:
      Repo.all(
        from c in Chat, where: c.project_id == ^project_id and c.shipping == "pilot", select: c.id
      )

  @doc """
  How the chat's change ships (`Burrow.Ship`): "review", "pilot", or
  anything else for merging it when its checks pass (nil).
  """
  def pick_shipping(%Chat{} = chat, shipping),
    do: set(chat, shipping: if(shipping in ~w(review pilot), do: shipping))

  @doc """
  "Split into a horde": Peon splits big tasks into a horde by itself, `n`
  peons at a time (`Burrow.Hordes`); nil turns it off.
  """
  def pick_horde(%Chat{} = chat, n),
    do:
      set(chat,
        horde_at_once: if(is_integer(n), do: n |> max(1) |> min(Burrow.Hordes.max_at_once()))
      )

  @doc "The chat's agent from its next message; build is nil."
  def pick_agent(%Chat{} = chat, agent),
    do: set(chat, agent: if(agent in ~w(plan design), do: agent))

  defp model(model), do: if(is_binary(model) and model =~ ~r"\A[\w.-]+/\S+\z", do: model)
  defp effort(effort), do: if(is_binary(effort) and effort =~ ~r"\A[\w.-]+\z", do: effort)

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
