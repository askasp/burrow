defmodule Peon.PullRequest do
  @moduledoc """
  Submitting a repo chat (`Peon.Source`): Peon commits the chat's checkout,
  merges the repo's main branch into it, runs the preview pack's `check`,
  pushes branch `peon/<chat id>` and opens a pull request for it on GitHub,
  or finds the one it opened before. The agent only calls `submit_changeset`;
  the token stays with Peon (`Peon.Git`).

  A repo that is not on GitHub gets the push without a PR.
  """

  alias Peon.{Git, HostPreview, Source}

  @check_timeout :timer.minutes(15)

  @doc """
  Submits the checkout in `dir`. `title` is the commit message and the PR's
  title, `body` the PR's description; `check` is `{command, env}` or nil.

  Returns `{:ok, pr_url | nil}` or `{:error, reason}`: `:no_changes`,
  `:no_token`, `{:conflict, paths}` (the merge is left in progress for the
  agent to finish), `{:unresolved, paths}`, `{:check_failed, output}` or a
  message.
  """
  def submit(chat_id, dir, title, body, check \\ nil) do
    branch = "peon/#{chat_id}"
    github = github()

    with :ok <- token(github, chat_id),
         {:ok, author} <- author(github),
         :ok <- resolved(dir),
         :ok <- commit(dir, branch, title, author),
         :ok <- merge_main(dir, author),
         :ok <- run_check(dir, check),
         :ok <- push(dir, branch, chat_id) do
      if github, do: open(github, branch, title, body), else: {:ok, nil}
    end
  end

  # owner and repo when the repo is on GitHub
  defp github do
    case Regex.run(~r{\Ahttps://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?\z}, Source.repo().url) do
      [_, owner, repo] -> {owner, repo}
      nil -> nil
    end
  end

  defp token(nil, _chat_id), do: :ok

  defp token(_github, chat_id) do
    if Git.token(), do: :ok, else: no_token(chat_id)
  end

  defp no_token(chat_id) do
    Git.request_token(chat_id)
    {:error, :no_token}
  end

  # Commits are the token owner's; elsewhere they are Peon's.
  defp author(nil), do: {:ok, identity("Peon", "peon@localhost")}

  defp author(_github) do
    case Req.get(req(), url: "/user") do
      {:ok, %{status: 200, body: %{"login" => login, "id" => id} = user}} ->
        {:ok, identity(user["name"] || login, "#{id}+#{login}@users.noreply.github.com")}

      response ->
        failed("read the token's user", response)
    end
  end

  defp identity(name, email) do
    for kind <- ~w(AUTHOR COMMITTER),
        {key, value} <- [{"NAME", name}, {"EMAIL", email}],
        do: {"GIT_#{kind}_#{key}", value}
  end

  # A merge left in progress by an earlier submit must have its conflicts resolved.
  defp resolved(dir) do
    with {:ok, out} <- Git.git(["diff", "--name-only", "--diff-filter=U"], cd: dir) do
      case Enum.filter(String.split(out, "\n", trim: true), &markers?(dir, &1)) do
        [] -> :ok
        paths -> {:error, {:unresolved, paths}}
      end
    end
  end

  defp markers?(dir, path) do
    case File.read(Path.join(dir, path)) do
      {:ok, content} -> content =~ ~r/^(<<<<<<<|>>>>>>>) /m
      {:error, _} -> false
    end
  end

  # Nothing to submit: no edits and nothing the last push didn't have.
  defp commit(dir, branch, title, author) do
    base =
      case Git.git(["rev-parse", "--verify", "-q", "origin/#{branch}"], cd: dir) do
        {:ok, _} -> "origin/#{branch}"
        {:error, _} -> "origin/#{Source.repo().branch}"
      end

    with {:ok, _} <- Git.git(["add", "-A"], cd: dir),
         {:ok, staged} <- Git.git(["diff", "--cached", "--name-only"], cd: dir),
         {:ok, ahead} <- Git.git(["rev-list", "--count", "#{base}..HEAD"], cd: dir) do
      merging? = File.exists?(Path.join([dir, ".git", "MERGE_HEAD"]))

      cond do
        staged != "" or merging? ->
          with {:ok, _} <- Git.git(["commit", "-q", "-m", title], cd: dir, env: author),
               do: :ok

        String.trim(ahead) == "0" ->
          {:error, :no_changes}

        true ->
          :ok
      end
    end
  end

  defp merge_main(dir, author) do
    main = Source.repo().branch

    with {:ok, _} <- Git.git(["fetch", "origin", main], cd: dir) do
      case Git.git(["merge", "--no-edit", "origin/#{main}"], cd: dir, env: author) do
        {:ok, _} ->
          :ok

        {:error, output} ->
          case Git.git(["diff", "--name-only", "--diff-filter=U"], cd: dir) do
            {:ok, ""} -> {:error, output}
            {:ok, out} -> {:error, {:conflict, String.split(out, "\n", trim: true)}}
            error -> error
          end
      end
    end
  end

  defp run_check(_dir, nil), do: :ok

  defp run_check(dir, {command, env}) do
    case HostPreview.run(dir, command, env, @check_timeout) do
      {:ok, _} -> :ok
      {:error, output} -> {:error, {:check_failed, output}}
      :timeout -> {:error, {:check_failed, "it did not finish in 15 minutes"}}
    end
  end

  defp push(dir, branch, chat_id) do
    case Git.git(["push", "-q", "origin", "HEAD:refs/heads/#{branch}"], cd: dir) do
      {:ok, _} ->
        :ok

      {:error, output} ->
        if Git.needs_token?(output), do: no_token(chat_id), else: {:error, output}
    end
  end

  # The open PR for the branch, or a new one.
  defp open({owner, repo}, branch, title, body) do
    path = "/repos/#{owner}/#{repo}/pulls"

    case Req.get(req(), url: path, params: [head: "#{owner}:#{branch}", state: "open"]) do
      {:ok, %{status: 200, body: [%{"html_url" => url} | _]}} ->
        {:ok, url}

      {:ok, %{status: 200, body: []}} ->
        pr = %{title: title, body: body, head: branch, base: Source.repo().branch}

        case Req.post(req(), url: path, json: pr) do
          {:ok, %{status: 201, body: %{"html_url" => url}}} -> {:ok, url}
          response -> failed("open the PR", response)
        end

      response ->
        failed("look for the PR", response)
    end
  end

  defp failed(what, {:ok, %{status: status, body: body}}) do
    message = if is_map(body), do: body["message"], else: nil
    {:error, "GitHub would not #{what}: #{status}#{if message, do: " #{message}"}"}
  end

  defp failed(what, {:error, error}),
    do: {:error, "could not reach GitHub to #{what}: #{Exception.message(error)}"}

  defp req do
    Req.new(
      base_url: "https://api.github.com",
      auth: {:bearer, Git.token()},
      headers: [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ],
      retry: false
    )
    |> Req.merge(Application.get_env(:peon, :github_req, []))
  end
end
