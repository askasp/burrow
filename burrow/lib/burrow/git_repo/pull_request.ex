defmodule Burrow.GitRepo.PullRequest do
  @moduledoc """
  Submitting a repo chat (`Burrow.GitRepo`): Burrow commits the chat's checkout,
  merges the repo's main branch into it, runs the preview pack's `check`,
  pushes branch `peon/<chat id>` and opens a pull request for it on GitHub,
  or finds the one it opened before. The agent only calls `submit_changeset`;
  the token stays with Burrow.

  A repo that is not on GitHub gets the push without a PR.

  The agent reads the repo's other pull requests through Burrow too
  (`read/4`, `open_list/2`), since it has no GitHub access of its own.
  `refresh/1` notes which chats' PRs were merged or closed
  (`Burrow.GitRepo.Merged` closes the merged ones' chats).
  """

  alias Burrow.{Chats, GitRepo, Projects}
  alias Burrow.GitRepo.HostPreview

  @check_timeout :timer.minutes(15)

  @doc """
  Submits the checkout in `dir`. `title` is the commit message and the PR's
  title, `body` the PR's description; `check` is `{command, env}` or nil.

  Returns `{:ok, pr_url | nil}` or `{:error, reason}`: `:no_changes`,
  `:no_token`, `{:conflict, paths}` (the merge is left in progress for the
  agent to finish), `{:unresolved, paths}`, `{:check_failed, output}` or a
  message.
  """
  def submit(project, chat_id, dir, title, body, check \\ nil) do
    branch = "peon/#{chat_id}"
    github = github(project)
    git = &GitRepo.git(project, &1, &2)

    with :ok <- token(project, github, chat_id),
         {:ok, author} <- author(project, github),
         :ok <- resolved(git, dir),
         :ok <- commit(project, git, dir, branch, title, author),
         :ok <- merge_main(project, git, dir, author),
         :ok <- run_check(dir, check),
         :ok <- push(project, git, dir, branch, chat_id) do
      if github, do: open(project, github, branch, title, body), else: {:ok, nil}
    end
  end

  @doc """
  Pull request `number` (GitHub's PR object), with its head fetched into the
  checkout in `dir` as `origin/pr/<number>` and its base branch as
  `origin/<base>`. Errors are `:not_github`, `:no_token` or a message.
  """
  def read(project, chat_id, dir, number) do
    with {:ok, {owner, repo}} <- on_github(project, chat_id),
         {:ok, pr} <- get(project, "/repos/#{owner}/#{repo}/pulls/#{number}", "read ##{number}"),
         base = pr["base"]["ref"],
         {:ok, _} <-
           GitRepo.git(
             project,
             [
               "fetch",
               "-q",
               "origin",
               "+refs/pull/#{number}/head:refs/remotes/origin/pr/#{number}",
               "+refs/heads/#{base}:refs/remotes/origin/#{base}"
             ],
             cd: dir
           ) do
      {:ok, pr}
    end
  end

  @doc "The repo's open pull requests, newest first, like `read/4`'s without the fetch."
  def open_list(project, chat_id) do
    with {:ok, {owner, repo}} <- on_github(project, chat_id) do
      get(project, "/repos/#{owner}/#{repo}/pulls", "list the PRs", state: "open", per_page: 50)
    end
  end

  @doc """
  What people and bots (Copilot's reviews too) said on pull request `number`,
  oldest first: comments on the PR, reviews and comments on lines of code,
  up to 100 of each. Each is `%{author, at, body}`, plus `review` (`"approved"`,
  `"changes requested"`, `"commented"`, `"dismissed"`) for a review and `path`,
  `line`, `outdated` and `thread` (its first comment's id, for `comment/5`)
  for a comment on code. Errors like `read/4`'s.
  """
  def comments(project, chat_id, number) do
    with {:ok, {owner, repo}} <- on_github(project, chat_id),
         pr = "/repos/#{owner}/#{repo}/pulls/#{number}",
         {:ok, talk} <-
           get(project, "/repos/#{owner}/#{repo}/issues/#{number}/comments", "read the comments",
             per_page: 100
           ),
         {:ok, reviews} <- get(project, "#{pr}/reviews", "read the reviews", per_page: 100),
         {:ok, code} <- get(project, "#{pr}/comments", "read the code comments", per_page: 100) do
      reviews =
        for %{"state" => state} = review <- reviews,
            state != "PENDING",
            # an empty COMMENTED review only holds comments on code
            state != "COMMENTED" or String.trim(review["body"] || "") != "",
            do: Map.put(said(review, review["submitted_at"]), :review, review_state(state))

      code =
        for comment <- code do
          Map.merge(said(comment, comment["created_at"]), %{
            path: comment["path"],
            line: comment["line"] || comment["original_line"],
            outdated: comment["line"] == nil and comment["original_line"] != nil,
            # GitHub takes replies to a thread's first comment only
            thread: comment["in_reply_to_id"] || comment["id"]
          })
        end

      talk = for comment <- talk, do: said(comment, comment["created_at"])
      {:ok, Enum.sort_by(talk ++ reviews ++ code, & &1.at)}
    end
  end

  @doc """
  Posts `body` on pull request `number` as the token's user: a reply in
  `thread` (a comment on code, `comments/3`) or, without one, a comment on
  the PR. Returns `{:ok, url}`; errors like `read/4`'s.
  """
  def comment(project, chat_id, number, body, thread \\ nil) do
    with {:ok, {owner, repo}} <- on_github(project, chat_id) do
      {path, what} =
        if thread,
          do: {"/repos/#{owner}/#{repo}/pulls/#{number}/comments/#{thread}/replies", "reply"},
          else: {"/repos/#{owner}/#{repo}/issues/#{number}/comments", "comment"}

      case Req.post(req(project), url: path, json: %{body: body}) do
        {:ok, %{status: 201, body: %{"html_url" => url}}} -> {:ok, url}
        response -> failed(what, response)
      end
    end
  end

  defp said(item, at) do
    # a deleted account has no user
    author = item["user"]["login"] || "ghost"
    %{author: author, at: at || "", body: String.trim(item["body"] || "")}
  end

  defp review_state(state), do: state |> String.downcase() |> String.replace("_", " ")

  @doc """
  Asks GitHub about every chat's PR not known to be merged or closed, and
  saves the state of those that changed (`Burrow.Chats.Chat`'s
  `pr_state`). Returns how many changed; 0 when GitHub can't be asked.
  """
  def refresh(project) do
    with {owner, repo} <- github(project),
         token when token != nil <- GitRepo.token(project) do
      changed =
        for %{pr_url: url, pr_state: state} = chat <- Chats.list(project.id),
            url != nil and state in [nil, "open"],
            [_, number] <- [Regex.run(~r{/pull/(\d+)\z}, url)],
            {:ok, pr} <- [get(project, "/repos/#{owner}/#{repo}/pulls/#{number}", "read")],
            pr_state(pr) != state do
          Chats.set(chat, pr_state: pr_state(pr))
        end

      if changed != [], do: Projects.broadcast(project.id, "chats", :prs_changed)
      length(changed)
    else
      _ -> 0
    end
  end

  defp pr_state(%{"merged_at" => at}) when at != nil, do: "merged"
  defp pr_state(%{"state" => state}), do: state

  defp on_github(project, chat_id) do
    case github(project) do
      nil -> {:error, :not_github}
      github -> with :ok <- token(project, github, chat_id), do: {:ok, github}
    end
  end

  defp get(project, path, what, params \\ []) do
    case Req.get(req(project), url: path, params: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      response -> failed(what, response)
    end
  end

  # owner and repo when the repo is on GitHub
  defp github(project) do
    case Regex.run(~r{\Ahttps://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?\z}, project.repo_url) do
      [_, owner, repo] -> {owner, repo}
      nil -> nil
    end
  end

  defp token(_project, nil, _chat_id), do: :ok

  defp token(project, _github, chat_id) do
    if GitRepo.token(project), do: :ok, else: no_token(project, chat_id)
  end

  defp no_token(project, chat_id) do
    GitRepo.request_token(project, chat_id)
    {:error, :no_token}
  end

  # Commits are the token owner's; elsewhere they are Peon's.
  defp author(_project, nil), do: {:ok, identity("Peon", "peon@localhost")}

  defp author(project, _github) do
    case Req.get(req(project), url: "/user") do
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
  defp resolved(git, dir) do
    with {:ok, out} <- git.(["diff", "--name-only", "--diff-filter=U"], cd: dir) do
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
  defp commit(project, git, dir, branch, title, author) do
    base =
      case git.(["rev-parse", "--verify", "-q", "origin/#{branch}"], cd: dir) do
        {:ok, _} -> "origin/#{branch}"
        {:error, _} -> "origin/#{GitRepo.branch(project)}"
      end

    with {:ok, _} <- git.(["add", "-A"], cd: dir),
         {:ok, staged} <- git.(["diff", "--cached", "--name-only"], cd: dir),
         {:ok, ahead} <- git.(["rev-list", "--count", "#{base}..HEAD"], cd: dir) do
      merging? = File.exists?(Path.join([dir, ".git", "MERGE_HEAD"]))

      cond do
        staged != "" or merging? ->
          with {:ok, _} <- git.(["commit", "-q", "-m", title], cd: dir, env: author),
               do: :ok

        String.trim(ahead) == "0" ->
          {:error, :no_changes}

        true ->
          :ok
      end
    end
  end

  defp merge_main(project, git, dir, author) do
    main = GitRepo.branch(project)

    with {:ok, _} <- git.(["fetch", "origin", main], cd: dir) do
      case git.(["merge", "--no-edit", "origin/#{main}"], cd: dir, env: author) do
        {:ok, _} ->
          :ok

        {:error, output} ->
          case git.(["diff", "--name-only", "--diff-filter=U"], cd: dir) do
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

  defp push(project, git, dir, branch, chat_id) do
    case git.(["push", "-q", "origin", "HEAD:refs/heads/#{branch}"], cd: dir) do
      {:ok, _} ->
        :ok

      {:error, output} ->
        if GitRepo.needs_token?(project, output),
          do: no_token(project, chat_id),
          else: {:error, output}
    end
  end

  # The open PR for the branch, or a new one.
  defp open(project, {owner, repo}, branch, title, body) do
    path = "/repos/#{owner}/#{repo}/pulls"

    case Req.get(req(project), url: path, params: [head: "#{owner}:#{branch}", state: "open"]) do
      {:ok, %{status: 200, body: [%{"html_url" => url} | _]}} ->
        {:ok, url}

      {:ok, %{status: 200, body: []}} ->
        pr = %{title: title, body: body, head: branch, base: GitRepo.branch(project)}

        case Req.post(req(project), url: path, json: pr) do
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

  defp req(project) do
    Req.new(
      base_url: "https://api.github.com",
      auth: {:bearer, GitRepo.token(project)},
      headers: [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ],
      retry: false
    )
    |> Req.merge(Application.get_env(:burrow, :github_req, []))
  end
end
