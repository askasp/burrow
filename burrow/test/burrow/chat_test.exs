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

  test "ports browsers refuse are never used" do
    refute Burrow.Ports.browser_safe?(5060)
    refute Burrow.Ports.browser_safe?(5061)
    assert Burrow.Ports.browser_safe?(5062)
  end
end
