defmodule Peon.InlineTest do
  use Peon.DataCase, async: false

  alias Peon.{Chats, Code, Inline, Project, Ship, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do end")
    {:ok, base} = Store.import_dir(dir, "app", "App", %{kind: :human, id: "aksel"})
    Project.put_settings(%{"envs" => "live", "auto_fix" => false})
    start_supervised!(Inline)
    %{base: base}
  end

  test "a live-only project: the checks pass, a human merges, and prod moves", %{base: base} do
    chat = inline_chat("Sort down checks first")
    {:ok, cs} = submit(chat.id, base.id)

    assert %{"changeset" => %{"phase" => "checking", "id" => id, "steps" => steps}} =
             Inline.state()

    assert id == cs.id
    assert Enum.map(steps, & &1["status"]) == ~w(running waiting waiting waiting)

    {:ok, cs} = Store.set_status(cs.id, "passed", %{"steps" => passed_steps()})
    assert Ship.after_checks(cs) == {:held, ["merging it puts it live"]}
    assert Inline.keep_alive?(chat.id)

    state = Inline.state()
    assert state["mode"] == "live"
    assert state["live"] == %{"tip" => nil, "good" => nil, "url" => nil, "status" => "not_built"}
    assert %{"phase" => "ready", "steps" => steps} = state["changeset"]
    assert Enum.all?(steps, &(&1["status"] == "passed"))

    assert {:ok, landed} = Inline.merge("aksel")
    assert landed.id == cs.id
    assert Code.ref("main").changeset_id == cs.id
    assert Code.ref("prod").changeset_id == cs.id
    assert Code.changeset(cs.id) |> elem(1) |> Map.get(:verify) |> Map.get("status") == "passed"
    refute Inline.keep_alive?(chat.id)

    # Prod isn't running in tests, so it stays on its way.
    assert %{"live" => %{"tip" => tip}, "changeset" => %{"phase" => "landing"}} = Inline.state()
    assert tip == cs.id
  end

  test "discard drops the changeset and ends the inline chat", %{base: base} do
    chat = inline_chat("Make it blue")
    {:ok, cs} = submit(chat.id, base.id)
    {:ok, _} = Store.set_status(cs.id, "passed", %{"steps" => passed_steps()})

    assert :ok = Inline.discard()
    assert {:ok, %{status: "superseded"}} = Code.changeset(cs.id)
    assert Project.settings()["inline_chat"] == nil
    assert Inline.state()["chat"] == nil
    assert Inline.state()["changeset"] == nil
    # The chat itself stays, for the workspace.
    assert Chats.get(chat.id)
  end

  test "adding staging and prod starts both at what is live", %{base: base} do
    chat = inline_chat("First version")
    {:ok, cs} = submit(chat.id, base.id)
    {:ok, _} = Store.set_status(cs.id, "passed", %{"steps" => passed_steps()})
    {:ok, _} = Inline.merge("aksel")

    assert :ok = Inline.add_envs("aksel")
    refute Ship.live_only?()
    assert Inline.state()["mode"] == "pipeline"
    assert Code.ref("staging").changeset_id == cs.id
    assert Code.ref("prod").changeset_id == cs.id

    # Pipeline rules again: AI changes land by themselves.
    {:ok, next} = submit(chat.id, cs.id, "defmodule App do def y, do: 2 end")
    {:ok, next} = Store.set_status(next.id, "passed", %{"steps" => passed_steps()})
    assert {:landed, _} = Ship.after_checks(next)
    assert Code.ref("prod").changeset_id == cs.id
  end

  test "the chat's model and effort go into its agent's config" do
    chat = Chats.create("Hi", "aksel", model: "openai/gpt-6-sol", effort: "high")
    assert {chat.model, chat.effort} == {"openai/gpt-6-sol", "high"}

    assert Peon.Chat.effort_config(chat.model, chat.effort) == %{
             "provider" => %{
               "openai" => %{
                 "models" => %{"gpt-6-sol" => %{"options" => %{"reasoningEffort" => "high"}}}
               }
             }
           }

    assert Peon.Chat.effort_config(chat.model, "medium") == %{}
    bad = Chats.create("Hi", "aksel", model: "rm -rf /", effort: "max")
    assert {bad.model, bad.effort} == {nil, nil}
  end

  defp inline_chat(title) do
    chat = Chats.create(title, "aksel")
    Project.put_settings(%{"inline_chat" => chat.id})
    # The running Inline follows the setting only through its own API; restart it.
    stop_supervised!(Inline)
    start_supervised!(Inline)
    chat
  end

  defp submit(chat_id, parent, content \\ "defmodule App do def x, do: 1 end") do
    Store.submit(%{
      parent: parent,
      intent: "change lib/app.ex",
      files: [%{"path" => "lib/app.ex", "content" => content}],
      author: %{kind: :ai, id: chat_id},
      conversation_id: chat_id
    })
  end

  defp passed_steps,
    do: for(name <- ~w(deps compile format test), do: %{"name" => name, "status" => "passed"})
end
