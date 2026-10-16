defmodule Peon.Agent.Tools do
  @moduledoc """
  The tools Peon adds to the agent (served over MCP by `Peon.Agent.MCP`).
  Everything else (reading, editing, running tests) the agent does with its
  own tools in the chat's workspace.

  `call/3` returns `{text, failed?}`.
  """

  alias Peon.{Chat, Chats, Checks, Env, Secrets, Store, Workspace}

  @check_timeout :timer.minutes(15)

  def specs do
    [
      %{
        name: "submit_changeset",
        description: """
        Submit all your changes in /app as a changeset. Peon checks policy, compiles with \
        warnings as errors and checks formatting in a clean sandbox. When that passes the \
        change lands on main right away (unless it needs the user's review); main's tests \
        run after that and it deploys to staging. On failure, fix the problem and submit \
        again.\
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
      },
      %{
        name: "restore",
        description: """
        Undo your changes to files in /app: puts each path back as it is on main (your \
        checkout's base), or removes it if main doesn't have it. There is no git in /app; \
        use this instead of git checkout.\
        """,
        parameters: %{
          type: "object",
          properties: %{paths: %{type: "array", items: %{type: "string"}}},
          required: ["paths"]
        }
      },
      %{
        name: "runtime",
        description: """
        Look into a running environment of the app, like observer. what: "overview" \
        (status, deployed changeset, memory, process count, run queue, recent errors with \
        stacktraces) or "processes" (top processes, sorted by "memory", "reductions" or \
        "message_queue_len").\
        """,
        parameters: %{
          type: "object",
          properties: %{
            env: %{type: "string", enum: ["staging", "prod"]},
            what: %{type: "string", enum: ["overview", "processes"]},
            sort: %{type: "string", enum: ["memory", "reductions", "message_queue_len"]}
          },
          required: ["env", "what"]
        }
      },
      %{
        name: "secrets",
        description: """
        List the project's secrets: API keys, tokens and passwords the user keeps in Peon. \
        You see names only. Every set secret is an environment variable in the preview, \
        staging and prod; read it where it is used with System.get_env("NAME"), at run \
        time, never in a module attribute or config. Your shell and the tests don't have \
        them: tests use fakes.\
        """,
        parameters: %{type: "object", properties: %{}}
      },
      %{
        name: "request_secret",
        description: """
        Ask the user for a secret the app needs (an API key, a token, a shared password). \
        The chat shows them a box to paste it into; you get a message here once it is set. \
        Meanwhile write the code that reads it with System.get_env/1 and handles it \
        missing. Never ask for a secret in your answer text or put one in code.\
        """,
        parameters: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "Environment variable name in capitals, like SLACK_TOKEN"
            },
            why: %{
              type: "string",
              description:
                "One short line for the user: what it is for and where to get it, like " <>
                  "\"Posts to #ops. Slack app, OAuth & Permissions, Bot token.\""
            }
          },
          required: ["name", "why"]
        }
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

  def call("restore", %{"paths" => paths}, chat_id) when is_list(paths) do
    {_base, changes} = Workspace.changes(Chat.workspace_dir(chat_id))
    changed = MapSet.new(changes, &elem(&1, 0))
    {known, unknown} = Enum.split_with(paths, &MapSet.member?(changed, &1))
    :ok = Workspace.restore(Chat.workspace_dir(chat_id), known)

    text =
      "Restored #{length(known)} file(s) to main's version." <>
        if(unknown == [], do: "", else: " Not changed, left alone: #{Enum.join(unknown, ", ")}")

    {text, false}
  end

  def call("runtime", %{"env" => env, "what" => what} = args, _chat_id) do
    if env in Env.names() do
      case Env.runtime(env, what, Map.take(args, ["sort", "limit"])) do
        {:ok, result} -> {Jason.encode!(result, pretty: true), false}
        {:error, reason} -> {"Could not inspect #{env}: #{inspect(reason)}", true}
      end
    else
      {"There is no #{env} environment.", true}
    end
  end

  def call("secrets", _args, _chat_id) do
    case Secrets.list() do
      [] ->
        {"No secrets yet. Ask the user for one with request_secret.", false}

      secrets ->
        {Enum.map_join(secrets, "\n", fn s ->
           if s.set?, do: "- #{s.name}: set", else: "- #{s.name}: asked for, not set yet"
         end), false}
    end
  end

  def call("request_secret", %{"name" => name, "why" => why}, chat_id)
      when is_binary(name) and is_binary(why) do
    case Secrets.request(name, String.slice(why, 0, 300), chat_id) do
      {:ok, :already_set} ->
        {"#{name} is already set. Read it with System.get_env(\"#{name}\").", false}

      {:ok, :requested} ->
        {"Asked the user for #{name}. You get a message here once it is set. Meanwhile " <>
           "read it with System.get_env(\"#{name}\") and handle it missing.", false}

      {:error, message} ->
        {message, true}
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
      {:checked, ^id, status, checks, outcome} ->
        {report(id, status, checks, outcome),
         status == "failed" or match?({:not_landed, _}, outcome)}

      {:checked, _, _, _, _} ->
        await_checks(id)

      {:check_step, _, _, _} ->
        await_checks(id)
    after
      @check_timeout -> {"Checks for changeset #{id} did not finish in time.", true}
    end
  end

  defp report(id, "passed", checks, outcome) do
    steps = Enum.map_join(checks["steps"], ", ", &"#{&1["name"]} ok")
    "Changeset #{id} passed its checks (#{steps}). " <> outcome(outcome)
  end

  defp report(id, "failed", checks, _outcome) do
    failed = Enum.find(checks["steps"], &(&1["status"] == "failed"))

    """
    Changeset #{id}: checks FAILED at step "#{failed["name"]}".

    #{failed["output"]}

    Fix this in /app and call submit_changeset again.\
    """
  end

  defp outcome({:landed, main_id}) do
    staging = if "staging" in Env.names(), do: Env.info("staging"), else: nil

    "It landed on main as ##{main_id}. Main's tests run next; if your change breaks them " <>
      "you will get a message here. Once they pass it is hot-loaded into staging" <>
      if(staging, do: " (#{staging.url}).", else: ".")
  end

  defp outcome({:held, reasons}) do
    "It needs the user to land it because #{Enum.join(reasons, "; ")}. Tell the user what " <>
      "it does and why it needs their review."
  end

  defp outcome({:not_landed, {:conflict, paths}}) do
    """
    It did not land: main changed #{Enum.join(paths, ", ")} since your checkout. Your \
    workspace is now on the new main and keeps your version of those files; main's version \
    of each is in .peon/main/<path>. Merge main's changes into your files and submit again.\
    """
  end

  defp outcome({:not_landed, reason}), do: "It did not land: " <> describe_error(reason)
  defp outcome(nil), do: ""

  defp describe_error({:policy, violations}), do: Enum.map_join(violations, "\n", & &1.reason)

  defp describe_error({:conflict, paths}),
    do: "main changed the same files since your checkout: #{Enum.join(paths, ", ")}"

  defp describe_error({:invalid, message}), do: message
  defp describe_error({:rejected, message}), do: message
  defp describe_error(other), do: inspect(other)
end
