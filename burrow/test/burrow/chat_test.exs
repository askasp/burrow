defmodule Burrow.ChatTest do
  use ExUnit.Case, async: true

  alias Burrow.Chat

  defp assistant(parts), do: %{"type" => "assistant", "id" => "m1", "content" => parts}

  test "Peon's tools called through code mode show the tool and Peon's answer" do
    part = %{
      "type" => "tool",
      "name" => "execute",
      "state" => %{
        "status" => "completed",
        "input" => %{"code" => "return await tools.peon.submit_changeset({intent: \"x\"})"},
        "content" => [
          %{
            "type" => "text",
            "text" => "Changeset 7 passed its checks. It needs the user to land it."
          }
        ],
        "metadata" => %{
          "toolCalls" => [
            %{"tool" => "peon.submit_changeset", "input" => %{"intent" => "Add schedules"}}
          ]
        }
      }
    }

    assert [
             %{
               role: :tool,
               text: "peon.submit_changeset Add schedules",
               peon?: true,
               detail: detail
             }
           ] =
             Chat.normalize(assistant([part]))

    assert detail =~ "needs the user to land it"
  end

  test "patches show their files; failed tools keep their output, others don't" do
    patch = %{
      "type" => "tool",
      "name" => "patch",
      "state" => %{
        "status" => "completed",
        "input" => %{
          "patchText" =>
            "*** Begin Patch\n*** Update File: lib/a.ex\n*** Add File: lib/b.ex\n*** End Patch"
        },
        "content" => [%{"type" => "text", "text" => "Success"}]
      }
    }

    failed = %{
      "type" => "tool",
      "name" => "shell",
      "state" => %{
        "status" => "error",
        "input" => %{"command" => "mix test"},
        "content" => [%{"type" => "text", "text" => "1 failure"}]
      }
    }

    assert [
             %{text: "patch lib/a.ex lib/b.ex", detail: nil},
             %{text: "shell mix test", detail: "1 failure"}
           ] =
             Chat.normalize(assistant([patch, failed]))
  end

  test "a message sent with a skill shows it as typed" do
    user = &%{"type" => "user", "id" => "u1", "text" => &1, "skills" => [%{"id" => "deploy"}]}

    assert [%{role: :user, text: "/deploy to staging"}] = Chat.normalize(user.("to staging"))
    assert [%{role: :user, text: "/deploy"}] = Chat.normalize(user.("/deploy"))
  end

  test "a message's images show by the names Burrow keeps them under, not their data" do
    message = %{
      "type" => "user",
      "id" => "u1",
      "text" => "Like this",
      "files" => [
        %{"data" => "iVBORw0K", "mime" => "image/png", "name" => "k2j4.png"},
        %{"data" => "JVBERi0", "mime" => "application/pdf", "name" => "spec.pdf"}
      ]
    }

    assert [%{role: :user, text: "Like this", images: ["k2j4.png"]} = m] = Chat.normalize(message)
    refute inspect(m) =~ "iVBORw0K"
  end

  test "a message still in opencode's inbox shows as typed, without Peon's queue hint" do
    hint =
      "\n\n(Peon: if this asks for more than one thing, first put each in your queue " <>
        "with `tk create`, then work them one at a time.)"

    waiting = %{
      "type" => "user",
      "id" => "msg_1",
      "delivery" => "steer",
      "payload" => %{"text" => "Also add a footer" <> hint}
    }

    assert [%{id: "msg_1", role: :user, text: "Also add a footer", images: []}] =
             Chat.normalize(waiting)
  end

  test "Burrow's own keep-going input is a note of its kind" do
    synthetic = %{
      "type" => "synthetic",
      "id" => "s1",
      "text" => "The goal isn't met yet: 2 tests fail",
      "description" => "goal"
    }

    assert [%{role: :note, kind: "goal", text: "The goal isn't met yet: 2 tests fail"}] =
             Chat.normalize(synthetic)
  end

  test "a compacted conversation is a note; one that failed says why" do
    compacted = %{
      "type" => "compaction",
      "id" => "c1",
      "status" => "completed",
      "reason" => "manual",
      "summary" => "## Objective\n- ..."
    }

    assert [%{role: :note, kind: "compact", text: "conversation compacted to a summary"}] =
             Chat.normalize(compacted)

    failed = %{
      "type" => "compaction",
      "id" => "c2",
      "status" => "failed",
      "reason" => "manual",
      "error" => %{"type" => "provider.auth", "message" => "Your token has expired."}
    }

    assert [%{role: :error, text: "Could not compact: Your token has expired."}] =
             Chat.normalize(failed)

    assert [] = Chat.normalize(%{failed | "status" => "running"})
  end

  test "a model without a login falls back to the agent's first model" do
    ids = ["opencode/minimax-free", "opencode/big-pickle"]
    assert Burrow.OpenCode.usable("openai/gpt-6-sol", ids) == "opencode/minimax-free"
    assert Burrow.OpenCode.usable("opencode/big-pickle", ids) == "opencode/big-pickle"
    assert Burrow.OpenCode.usable("openai/gpt-6-sol", []) == "openai/gpt-6-sol"
  end

  test "ports browsers refuse are never used" do
    refute Burrow.Ports.browser_safe?(5060)
    refute Burrow.Ports.browser_safe?(5061)
    assert Burrow.Ports.browser_safe?(5062)
  end
end
