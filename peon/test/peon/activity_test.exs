defmodule Peon.ActivityTest do
  use Peon.DataCase, async: false

  alias Peon.{Activity, Chats, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    {:ok, base} = Store.import_dir(dir, "app", "App", %{kind: :human, id: "peon"})
    %{base: base}
  end

  test "a chat's phase follows its agent and its one changeset", %{base: base} do
    {:ok, empty} = Chats.create_empty("ada")
    talked = Chats.create("Talked", "ada")
    ready = Chats.create("Ready", "ada")
    cs = passed(base.id, ready.id)

    phases = fn busy -> Map.new(Activity.chats(busy), &{&1.chat.id, &1.phase}) end

    assert phases.(MapSet.new()) == %{empty.id => "new", talked.id => "idle", ready.id => "ready"}
    assert phases.(MapSet.new([talked.id]))[talked.id] == "working"

    # A live-only project: merging puts it live.
    Peon.Project.put_settings(%{"envs" => "live"})
    {:ok, _} = Peon.Ship.merge(cs.id, "ada")
    assert phases.(MapSet.new())[ready.id] == "live"
  end

  test "the project's tile: waiting on you while a changeset waits, new until built", %{
    base: base
  } do
    assert %{"state" => "waiting", "label" => "new"} =
             Activity.project(Activity.chats(MapSet.new()))

    chat = Chats.create("Ready", "ada")
    passed(base.id, chat.id)

    assert %{"state" => "waiting", "label" => "waiting on you"} =
             Activity.project(Activity.chats(MapSet.new()))

    assert %{"state" => "working", "pct" => 40} =
             Activity.project(Activity.chats(MapSet.new([chat.id])))
  end

  defp passed(parent, chat_id) do
    {:ok, cs} =
      Store.submit(%{
        parent: parent,
        intent: "change lib/app.ex",
        files: [%{"path" => "lib/app.ex", "content" => "defmodule App do end"}],
        author: %{kind: :ai, id: "agent"},
        conversation_id: chat_id
      })

    {:ok, cs} = Store.set_status(cs.id, "passed", %{"steps" => []})
    cs
  end
end
