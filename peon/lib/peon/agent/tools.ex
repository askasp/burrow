defmodule Peon.Agent.Tools do
  @moduledoc """
  The tools Peon adds to the agent (served over MCP by `Peon.Agent.MCP`).
  Everything else (reading, editing, running tests) the agent does with its
  own tools in the chat's workspace.

  `call/3` returns `{text, failed?}`.
  """

  alias Peon.{Chat, Chats, Checks, Code, Store, Workspace}

  @check_timeout :timer.minutes(15)

  def specs do
    [
      %{
        name: "submit_changeset",
        description: """
        Submit all your changes in /app as a changeset. Peon checks policy, compiles with \
        warnings as errors, checks formatting and runs the tests in a clean sandbox, then \
        returns the result. On failure, fix the problem and submit again.\
        """,
        parameters: %{
          type: "object",
          properties: %{
            intent: %{
              type: "string",
              description: "One sentence: what this change does for users"
            }
          },
          required: ["intent"]
        }
      },
      %{
        name: "restart_preview",
        description: """
        Restart the live preview: fetch deps, migrate the dev database and start the app \
        again. Use it after adding migrations or changing mix.exs or config.\
        """,
        parameters: %{type: "object", properties: %{}}
      }
    ]
  end

  def call("submit_changeset", %{"intent" => intent}, chat_id) when is_binary(intent) do
    submit(chat_id, intent)
  end

  def call("restart_preview", _args, chat_id) do
    case Chat.restart_preview(chat_id) do
      :ok -> {"The preview is restarting. Check it with curl in a minute.", false}
      {:error, reason} -> {"Could not restart the preview: #{inspect(reason)}", true}
    end
  end

  def call(name, _args, _chat_id), do: {"Unknown tool or missing arguments: #{name}", true}

  defp submit(chat_id, intent) do
    {base_id, changes} = Workspace.changes(Chat.workspace_dir(chat_id))

    files =
      for {path, change} <- changes do
        if change == :deleted,
          do: %{"path" => path, "deleted" => true},
          else: %{"path" => path, "content" => change}
      end

    previous = Chats.draft(chat_id)
    Checks.subscribe()

    attrs = %{
      parent: base_id,
      intent: intent,
      files: files,
      author: %{kind: :ai, id: chat_id},
      conversation_id: chat_id
    }

    cond do
      files == [] ->
        {"There are no changes in /app to submit.", true}

      true ->
        case Store.submit(attrs) do
          {:ok, cs} ->
            if previous && previous.id != cs.id, do: Store.supersede(previous.id)
            await_checks(cs.id)

          {:error, reason} ->
            {"Rejected: " <> describe_error(reason), true}
        end
    end
  end

  defp await_checks(id) do
    receive do
      {:checked, ^id, status, checks} -> {report(id, status, checks), status == "failed"}
      {:checked, _, _, _} -> await_checks(id)
      {:check_step, _, _, _} -> await_checks(id)
    after
      @check_timeout -> {"Checks for changeset #{id} did not finish in time.", true}
    end
  end

  defp report(id, "passed", checks) do
    steps = Enum.map_join(checks["steps"], ", ", &"#{&1["name"]} ok")
    main = Code.ref("main")

    "Changeset #{id}: all checks passed (#{steps}). The user can now accept it onto main" <>
      if(main && main.changeset_id == id, do: " (it already is).", else: ".")
  end

  defp report(id, "failed", checks) do
    failed = Enum.find(checks["steps"], &(&1["status"] == "failed"))

    """
    Changeset #{id}: checks FAILED at step "#{failed["name"]}".

    #{failed["output"]}

    Fix this in /app and call submit_changeset again.\
    """
  end

  defp describe_error({:policy, violations}), do: Enum.map_join(violations, "\n", & &1.reason)

  defp describe_error({:conflict, paths}),
    do: "main changed the same files since your checkout: #{Enum.join(paths, ", ")}"

  defp describe_error({:invalid, message}), do: message
  defp describe_error({:rejected, message}), do: message
  defp describe_error(other), do: inspect(other)
end
