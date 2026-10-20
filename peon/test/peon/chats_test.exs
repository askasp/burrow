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
end
