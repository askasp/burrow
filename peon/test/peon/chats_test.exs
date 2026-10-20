defmodule Peon.ChatsTest do
  use Peon.DataCase, async: false

  alias Peon.{Chat, Chats}

  test "a chat kept running stays so until its time is up" do
    chat = Chats.create("Share the preview", "ada@example.com")
    refute Chats.kept_running?(Chats.get(chat.id))

    Chats.keep_running(chat.id, 4)
    assert Chats.kept_running?(Chats.get(chat.id))
    assert [%{id: id}] = Chats.list_kept_running()
    assert id == chat.id

    Chats.keep_running(chat.id, nil)
    refute Chats.kept_running?(Chats.get(chat.id))
  end

  @tag :tmp_dir
  test "deleting a chat removes its row and files and tells the chat list", %{tmp_dir: dir} do
    previous = Application.get_env(:peon, :data_dir)
    Application.put_env(:peon, :data_dir, dir)
    on_exit(fn -> Application.put_env(:peon, :data_dir, previous) end)
    Chats.subscribe()
    chat = Chats.create("Throwaway", "ada@example.com")
    File.mkdir_p!(Chat.workspace_dir(chat.id))

    assert :ok = Chat.delete(chat.id)
    assert_receive {:chat_deleted, id} when id == chat.id
    assert Chats.get(chat.id) == nil
    refute File.exists?(Path.dirname(Chat.workspace_dir(chat.id)))
  end

  test "a project holds up to four chats" do
    for _ <- 1..4, do: assert({:ok, _} = Chats.create_empty("ada@example.com"))
    assert Chats.create_empty("ada@example.com") == {:error, :full}
    refute Chats.room?()
  end

  test "an empty chat takes its title from its first message" do
    Chats.subscribe()
    {:ok, chat} = Chats.create_empty("ada@example.com")
    assert %{title: "", started_at: nil} = Chats.get(chat.id)

    Chats.started(chat.id, "  Weekly uptime\n to #ops  ")
    assert_receive {:chat_started, _}
    assert %{title: "Weekly uptime to #ops", started_at: %DateTime{}} = Chats.get(chat.id)

    # Later messages leave it be.
    Chats.started(chat.id, "And on Fridays")
    assert Chats.get(chat.id).title == "Weekly uptime to #ops"
  end

  @tag :tmp_dir
  test "a new project starts with one empty chat, once", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    {:ok, _} = Peon.Store.import_dir(dir, "app", "App", %{kind: :human, id: "peon"})

    Chats.create_first()
    assert [%{title: "", started_at: nil} = chat] = Chats.list()

    Chats.delete(chat.id)
    Chats.create_first()
    assert Chats.list() == []
  end
end
