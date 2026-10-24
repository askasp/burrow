defmodule Burrow.GeneralChats do
  @moduledoc """
  Chats outside projects, the Chats space: a user's own, to ask, search
  and think, with no code and nothing to ship. The conversation lives in
  the chat's opencode session (`Burrow.GeneralChat`); Burrow keeps the
  chat's title, session, model and thinking level, its web search switch,
  how many sources its latest answer cites, and a copy of the conversation
  (`messages/1`), so the history reads without an agent running.

  A conversation moves only from here into a project, as the context of a
  new project chat (`Burrow.Chats.Chat`'s `from_chat`), never back.

  Broadcasts `{:general_created, chat}`, `{:general_changed, id}` and
  `{:general_deleted, id}` on the user's topic (`subscribe/1`);
  `Burrow.GeneralChat` broadcasts `{:general_busy, id, busy?}` there.
  """

  import Ecto.Query

  alias Burrow.Repo
  alias Burrow.GeneralChats.Chat

  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Burrow.PubSub, "general:#{user_id}")

  def broadcast(user_id, message),
    do: Phoenix.PubSub.broadcast(Burrow.PubSub, "general:#{user_id}", message)

  @doc "A chat's own topic: what its agent says (`Burrow.GeneralChat`)."
  def subscribe_chat(id), do: Phoenix.PubSub.subscribe(Burrow.PubSub, "general_chat:#{id}")

  def unsubscribe_chat(id), do: Phoenix.PubSub.unsubscribe(Burrow.PubSub, "general_chat:#{id}")

  def broadcast_chat(id, message),
    do: Phoenix.PubSub.broadcast(Burrow.PubSub, "general_chat:#{id}", message)

  @doc "An empty chat; its first message titles it. Options: `:model`, `:effort`."
  def create_empty(user_id, opts \\ []) do
    chat =
      Repo.insert!(%Chat{
        id: :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false),
        user_id: user_id,
        model: opts[:model],
        effort: opts[:effort]
      })

    broadcast(user_id, {:general_created, chat})
    chat
  end

  @doc "The user's chat `id`, nil when it isn't theirs."
  def get(user_id, id), do: Repo.get_by(Chat, id: id, user_id: user_id)

  def get(id), do: Repo.get(Chat, id)

  @doc "The user's chats, latest activity first."
  def list(user_id),
    do:
      Repo.all(
        from c in Chat,
          where: c.user_id == ^user_id,
          order_by: [desc: c.updated_at, desc: c.inserted_at, desc: c.id]
      )

  @doc "The user's chats whose title has `text`, latest first."
  def search(user_id, text) do
    case String.replace(text, ~r/[\\%_]/, "") |> String.trim() do
      "" ->
        []

      text ->
        Repo.all(
          from c in Chat,
            where: c.user_id == ^user_id and like(c.title, ^"%#{text}%"),
            order_by: [desc: c.updated_at, desc: c.id]
        )
    end
  end

  @doc "The chat got its first message: an empty chat takes its title from it."
  def started(%Chat{} = chat, text) do
    title = text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
    now = DateTime.utc_now(:second)
    query = from c in Chat, where: c.id == ^chat.id
    Repo.update_all(where(query, [c], is_nil(c.started_at)), set: [started_at: now])
    Repo.update_all(where(query, [c], c.title == ""), set: [title: title])
    Repo.update_all(query, set: [updated_at: now])
    broadcast(chat.user_id, {:general_changed, chat.id})
  end

  @doc "The chat's model and effort, as for a project chat (`Burrow.Chats.pick_model/3`)."
  def pick_model(%Chat{} = chat, model, effort),
    do: set(chat, model: valid_model(model), effort: valid_effort(effort))

  defp valid_model(model), do: if(is_binary(model) and model =~ ~r"\A[\w.-]+/\S+\z", do: model)
  defp valid_effort(effort), do: if(is_binary(effort) and effort =~ ~r"\A[\w.-]+\z", do: effort)

  def set(%Chat{id: id}, fields),
    do: Repo.update_all(from(c in Chat, where: c.id == ^id), set: fields)

  @doc "An answer is in: how many sources it cites, and the chat moves up the history."
  def answered(%Chat{} = chat, sources) do
    set(chat, sources: sources, updated_at: DateTime.utc_now(:second))
    broadcast(chat.user_id, {:general_changed, chat.id})
  end

  @doc "Deletes a chat: its agent, its files and its row."
  def delete(%Chat{} = chat) do
    Burrow.GeneralChat.stop(chat.id)
    Repo.delete_all(from c in Chat, where: c.id == ^chat.id)
    File.rm_rf(dir(chat))
    broadcast(chat.user_id, {:general_deleted, chat.id})
    :ok
  end

  @doc "Where the chat keeps its files: its agent's config, its copy of the conversation, its attachments."
  def dir(%Chat{user_id: user_id, id: id}),
    do:
      Path.join([Application.fetch_env!(:burrow, :data_dir), "users", "#{user_id}", "chats", id])

  @doc "The files sent with the chat's messages, by name."
  def files_dir(chat), do: Path.join(dir(chat), "files")

  @doc "The copy of the conversation, as `Burrow.GeneralChat` last saw it."
  def messages(chat) do
    case File.read(Path.join(dir(chat), "messages.bin")) do
      {:ok, data} -> :erlang.binary_to_term(data, [:safe])
      {:error, _} -> []
    end
  rescue
    ArgumentError -> []
  end

  def save_messages(chat, messages) do
    File.mkdir_p!(dir(chat))
    File.write!(Path.join(dir(chat), "messages.bin"), :erlang.term_to_binary(messages))
  end

  @doc """
  The pages the agent searched and read, by turn: the id of the user's
  message that started it => `[%{url, title, site, read?}]`
  (`Burrow.GeneralChats.Sources.pages/1`).
  """
  def pages(chat) do
    case File.read(Path.join(dir(chat), "pages.bin")) do
      {:ok, data} -> :erlang.binary_to_term(data, [:safe])
      {:error, _} -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  def save_pages(_chat, _turn, []), do: :ok

  def save_pages(chat, turn, pages) do
    File.mkdir_p!(dir(chat))
    data = chat |> pages() |> Map.put(turn, pages) |> :erlang.term_to_binary()
    File.write!(Path.join(dir(chat), "pages.bin"), data)
  end

  @doc """
  The conversation as text for a project chat's agent: what the user asked
  and what Peon answered, with the sources it cited, cut to the last
  `limit` characters.
  """
  def transcript(chat, limit \\ 20_000) do
    chat
    |> messages()
    |> Enum.flat_map(fn
      %{role: :user, text: text} -> ["User: " <> text]
      %{role: :assistant, text: text} -> ["Peon: " <> text]
      _ -> []
    end)
    |> Enum.join("\n\n")
    |> then(&if(String.length(&1) > limit, do: String.slice(&1, -limit..-1//1), else: &1))
  end
end
