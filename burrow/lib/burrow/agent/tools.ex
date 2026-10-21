defmodule Burrow.Agent.Tools do
  @moduledoc """
  The tools Peon adds to the agent (served over MCP by `Burrow.Agent.MCP`).
  Everything else (reading, editing, running tests) the agent does with its
  own tools in the chat's workspace.

  `call/3` returns `{text, failed?}`.
  """

  alias Burrow.{Chat, Chats, Env, Projects, Secrets, Ship, Workspace}
  alias Burrow.GitRepo.{PreviewPack, PullRequest}

  # A repo project has no history, checks or envs (`Burrow.GitRepo`).
  @repo_tools ~w(submit_changeset restart_preview secrets request_secret)

  def specs(project) do
    if Projects.Project.repo?(project),
      do: for(spec <- all_specs(), spec.name in @repo_tools, do: repo_spec(spec)),
      else: all_specs()
  end

  defp repo_spec(%{name: "submit_changeset"} = spec),
    do: %{
      spec
      | description: """
        Submit your changes in /app as a pull request, only when the user asks for it. \
        Peon commits them, merges the repo's main branch in, runs the preview pack's \
        check if it has one, pushes your branch and opens its PR, or updates the PR an \
        earlier submit opened. On failure, fix the problem and submit again.\
        """,
        parameters: %{
          type: "object",
          properties: %{
            intent: %{
              type: "string",
              description: "The PR's title and commit message: one line, what this changes"
            },
            description: %{
              type: "string",
              description: "The PR's description: what changed, why, and how you checked it"
            }
          },
          required: ["intent"]
        }
    }

  defp repo_spec(%{name: "restart_preview"} = spec),
    do: %{
      spec
      | description: """
        Restart the preview: run the preview pack's stop and start commands again, \
        re-reading .peon/preview.json. Use it after changing that file or anything the \
        dev servers only read when they start.\
        """
    }

  defp repo_spec(%{name: "secrets"} = spec),
    do: %{
      spec
      | description: """
        List the project's secrets: API keys, tokens and passwords the user keeps in Peon. \
        You see names only. Every set secret is an environment variable for the preview's \
        commands. Your shell doesn't have them.\
        """
    }

  defp repo_spec(spec), do: spec

  defp all_specs do
    [
      %{
        name: "submit_changeset",
        description: """
        Submit all your changes in /app. Peon checks policy, then compiles with warnings as \
        errors, checks the formatting of the files you changed and runs the tests, right \
        here in /app. When that passes the change lands on main: merged with what other \
        chats landed meanwhile. Main is then built and booted in prod mode, and the user \
        ships it. On failure, fix the problem and submit again.\
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
        Undo your changes to files in /app: puts each path back as it was in your \
        checkout's base, or removes it if the base doesn't have it. There is no git in /app; \
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
        (status, deployed change, memory, process count, run queue, recent errors with \
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

  def call(name, args, project, chat_id) do
    if Enum.any?(specs(project), &(&1.name == name)),
      do: run(name, args, project, chat_id),
      else: {"Unknown tool or missing arguments: #{name}", true}
  end

  defp run("submit_changeset", %{"intent" => intent} = args, project, chat_id) when is_binary(intent) do
    if Projects.Project.repo?(project),
      do: submit_pr(project, chat_id, intent, args["description"]),
      else: Ship.submit(project, chat_id, intent)
  end

  defp run("restart_preview", _args, _project, chat_id) do
    case Chat.restart_preview(chat_id) do
      :ok -> {"The preview is restarting. Check it with curl in a minute.", false}
      {:error, reason} -> {"Could not restart the preview: #{inspect(reason)}", true}
    end
  end

  defp run("restore", %{"paths" => paths}, project, chat_id) when is_list(paths) do
    dir = Chat.workspace_dir(project, chat_id)
    {_base, changes} = Workspace.changes(dir)
    changed = MapSet.new(changes, &elem(&1, 0))
    {known, unknown} = Enum.split_with(paths, &MapSet.member?(changed, &1))
    :ok = Workspace.restore(Projects.repo_dir(project), dir, known)

    text =
      "Restored #{length(known)} file(s)." <>
        if(unknown == [], do: "", else: " Not changed, left alone: #{Enum.join(unknown, ", ")}")

    {text, false}
  end

  defp run("runtime", %{"env" => env, "what" => what} = args, project, _chat_id) do
    if env in Env.names(project) do
      case Env.runtime(project, env, what, Map.take(args, ["sort", "limit"])) do
        {:ok, result} -> {Jason.encode!(result, pretty: true), false}
        {:error, reason} -> {"Could not inspect #{env}: #{inspect(reason)}", true}
      end
    else
      {"There is no #{env} environment.", true}
    end
  end

  defp run("secrets", _args, project, _chat_id) do
    case Secrets.list(project.id) do
      [] ->
        {"No secrets yet. Ask the user for one with request_secret.", false}

      secrets ->
        {Enum.map_join(secrets, "\n", fn s ->
           if s.set?, do: "- #{s.name}: set", else: "- #{s.name}: asked for, not set yet"
         end), false}
    end
  end

  defp run("request_secret", %{"name" => name, "why" => why}, project, chat_id)
       when is_binary(name) and is_binary(why) do
    case Secrets.request(project.id, name, String.slice(why, 0, 300), chat_id) do
      {:ok, :already_set} ->
        {"#{name} is already set. Read it with System.get_env(\"#{name}\").", false}

      {:ok, :requested} ->
        {"Asked the user for #{name}. You get a message here once it is set. Meanwhile " <>
           "read it with System.get_env(\"#{name}\") and handle it missing.", false}

      {:error, message} ->
        {message, true}
    end
  end

  defp run(name, _args, _project, _chat_id), do: {"Unknown tool or missing arguments: #{name}", true}

  defp submit_pr(project, chat_id, intent, description) do
    check =
      case Chat.preview_pack(chat_id) do
        {:ok, %PreviewPack{check: command}, env} when command != nil -> {command, env}
        _ -> nil
      end

    title = intent |> String.trim() |> String.split("\n") |> hd()
    chat = Chats.get(chat_id)
    body = String.trim("#{description}\n\nMade in Peon, chat \"#{chat.title}\".")

    case PullRequest.submit(project, chat_id, Chat.workspace_dir(project, chat_id), title, body, check) do
      {:ok, nil} ->
        {"Pushed branch peon/#{chat_id}. The repo is not on GitHub, so there is no PR; " <>
           "tell the user the branch.", false}

      {:ok, url} ->
        Chat.pr_opened(chat_id, url)

        {"Pushed branch peon/#{chat_id}; its pull request is #{url}. Give the user that " <>
           "link. Submit again after more changes: it updates the same PR.", false}

      {:error, reason} ->
        {pr_error(reason), true}
    end
  end

  defp pr_error(:no_changes), do: "There are no changes in /app to submit."

  defp pr_error(:no_token),
    do:
      "Peon needs the GITHUB_TOKEN secret to push and asked the user for it. Tell them, " <>
        "and submit again when you get the message that it is set."

  defp pr_error({:conflict, paths}) do
    """
    The repo's main branch changed the same lines as you in #{Enum.join(paths, ", ")}. \
    The merge is in progress in /app: resolve the conflict markers in those files, keeping \
    both sides' intent, check the preview, and submit again. Don't commit; Peon does.\
    """
  end

  defp pr_error({:unresolved, paths}),
    do:
      "These files still have conflict markers: #{Enum.join(paths, ", ")}. Resolve them " <>
        "and submit again."

  defp pr_error({:check_failed, output}) do
    """
    The preview pack's check failed, so nothing was pushed:

    #{String.slice(output, -4000, 4000)}

    Fix it and submit again.\
    """
  end

  defp pr_error(message), do: "Could not submit: #{message}"
end
