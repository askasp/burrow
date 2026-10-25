defmodule BurrowWeb.WorkspaceLive.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BurrowWeb.WorkspaceLive.Components

  defp tool(id, text, extra \\ %{}),
    do: Map.merge(%{id: id, role: :tool, text: text, status: "completed"}, extra)

  defp said(id, text), do: %{id: id, role: :assistant, text: text}

  describe "turn_items/1" do
    test "folds tool calls under what the agent said before them; the answer stays" do
      messages = [
        said("a", "Reading the code first.\nThen the tests."),
        tool("t1", "read /app/lib/app.ex"),
        tool("t2", "shell mix test"),
        said("b", "Now the fix:"),
        tool("t3", "edit /app/lib/app.ex"),
        said("c", "Done: the test passes.")
      ]

      assert [
               {:steps, %{id: "a"}, [%{id: "t1"}, %{id: "t2"}]},
               {:steps, %{id: "b"}, [%{id: "t3"}]},
               {:say, %{id: "c"}}
             ] = Components.turn_items(messages)
    end

    test "tools with nothing said before them fold untitled; notes stand alone" do
      messages = [
        tool("t1", "shell tk ready"),
        %{id: "n", role: :note, text: "Keep going", kind: "queue"},
        said("a", "All done.")
      ]

      assert [{:steps, nil, [%{id: "t1"}]}, {:note, %{id: "n"}}, {:say, %{id: "a"}}] =
               Components.turn_items(messages)
    end
  end

  describe "block/1" do
    test "a turn is what Peon said, then one line for its steps" do
      items =
        Components.turn_items([
          said("a", "Reading the code first."),
          tool("t1", "read /app/lib/app.ex"),
          tool("t2", "shell mix test Run the tests", %{about: "Run the tests"}),
          tool("t3", "shell mix test Run the tests", %{about: "Run the tests"}),
          tool("t4", "edit /app/lib/app.ex"),
          said("c", "Done.")
        ])

      html = render_component(&Components.block/1, block: {:peon, items, true})
      doc = LazyHTML.from_fragment(html)
      text = fn sel -> doc |> LazyHTML.query(sel) |> Enum.map(&LazyHTML.text/1) end

      # The answer, with Peon's "Zug zug."; the preamble isn't shown
      assert text.(".say-agent") == ["Zug zug. Done."]

      assert text.(".qline") |> Enum.map(&String.trim/1) ==
               ["Worked through 4 steps · 1 file changed"]

      # Repeats fold into one row: ×2
      assert [read, tests, edit] = text.(".srow")
      assert read =~ "Read app.ex" and read =~ "lib/"
      assert tests =~ "Run the tests" and tests =~ "×2" and tests =~ "mix test"
      assert edit =~ "Changed app.ex"
      # Folded until opened
      assert doc |> LazyHTML.query("details.qsteps[open]") |> Enum.empty?()
    end

    test "while the turn is live, what Peon said last stands in, its step marked" do
      items =
        Components.turn_items([
          said("a", "Looking around first."),
          tool("t1", "glob /app *.ex"),
          tool("t2", "shell ls -la")
        ])

      html = render_component(&Components.block/1, block: {:peon, items, false}, live: true)
      doc = LazyHTML.from_fragment(html)
      text = fn sel -> doc |> LazyHTML.query(sel) |> Enum.map(&LazyHTML.text/1) end

      assert text.(".say-agent") == ["Looking around first."]
      assert text.(".qline") |> Enum.map(&String.trim/1) == ["Working through 2 steps"]
      assert [now] = text.(".srow.now")
      assert now =~ "Looked at files"
    end

    test "a note splits the turn, each part with its own line" do
      items =
        Components.turn_items([
          tool("t1", "read /app/a.ex"),
          said("a", "One done."),
          %{id: "n", role: :note, text: "1 unfinished ticket", kind: "queue"},
          tool("t2", "read /app/b.ex"),
          said("b", "Two done.")
        ])

      html = render_component(&Components.block/1, block: {:peon, items, false})
      doc = LazyHTML.from_fragment(html)
      text = fn sel -> doc |> LazyHTML.query(sel) |> Enum.map(&LazyHTML.text/1) end

      assert text.(".say-agent") == ["One done.", "Two done."]
      assert length(text.(".qline")) == 2
      assert [note] = text.(".evt.note")
      assert note =~ "on to the last ticket in the queue"
    end
  end
end
