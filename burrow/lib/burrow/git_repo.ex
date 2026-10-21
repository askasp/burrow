defmodule Burrow.GitRepo do
  @moduledoc """
  A repo project: the user's existing git repo instead of a new app. Its
  chats use the same agent and preview pane, but the code comes from git:
  Burrow keeps one bare mirror (`<project dir>/repo.git`), fetched before
  each new chat, and gives each chat a clone of it on branch
  `peon/<chat id>`. The preview is the repo's own preview pack, run on the
  host (`Burrow.GitRepo.PreviewPack`, `Burrow.GitRepo.HostPreview`), and
  submitting pushes the branch and opens a PR (`Burrow.GitRepo.PullRequest`).
  There is no history in Burrow, no checks and no environments.

  git runs without the host's config or credentials: the only way in is the
  project's `GITHUB_TOKEN` secret, passed in the environment as an HTTP
  header, never written to disk. Public repos need no token.
  """

  alias Burrow.{Projects, Secrets}

  @token "GITHUB_TOKEN"

  @doc "The repo's main branch."
  def branch(_project), do: "main"

  def mirror_dir(project), do: Path.join(Projects.dir(project), "repo.git")

  @doc "Clones the repo into the mirror, or fetches it; one at a time per project."
  def sync(project) do
    :global.trans({{__MODULE__, project.id}, self()}, fn ->
      dir = mirror_dir(project)

      if File.dir?(dir) do
        with {:ok, _} <- git(project, ["fetch", "--prune", "origin"], cd: dir), do: :ok
      else
        tmp = dir <> ".tmp"
        File.rm_rf!(tmp)

        with {:ok, _} <- git(project, ["clone", "--bare", project.repo_url, tmp]),
             {:ok, _} <-
               git(project, ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"],
                 cd: tmp
               ) do
          File.rename!(tmp, dir)
          :ok
        end
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, output} ->
        if needs_token?(project, output), do: request_token(project, nil)
        {:error, output}
    end
  end

  @doc "Whether git failed for want of the token: no token is set and access was refused."
  def needs_token?(project, output),
    do:
      token(project) == nil and
        output =~ ~r/auth|could not read|not found|does not exist|denied|403|404/i

  @doc "Asks the user for the token; `chat_id` is told once it is set."
  def request_token(project, chat_id) do
    Secrets.request(
      project.id,
      @token,
      "Lets Burrow clone #{project.repo_url} and open PRs. GitHub, Settings, " <>
        "Developer settings, fine-grained token for this repo: Contents and " <>
        "Pull requests, read and write.",
      chat_id
    )
  end

  def token(project), do: Secrets.value(project.id, @token)

  def checked_out?(dir), do: File.dir?(Path.join(dir, ".git"))

  @doc "Makes `dir` a clone of the mirror on a new branch `peon/<chat_id>`, `origin` the real repo."
  def checkout(project, dir, chat_id) do
    File.mkdir_p!(Path.dirname(dir))
    File.rm_rf!(dir)

    with :ok <- sync(project),
         {:ok, _} <-
           git(project, [
             "clone",
             "--local",
             "--branch",
             branch(project),
             mirror_dir(project),
             dir
           ]),
         {:ok, _} <- git(project, ["checkout", "-b", "peon/#{chat_id}"], cd: dir),
         {:ok, _} <- git(project, ["remote", "set-url", "origin", project.repo_url], cd: dir) do
      :ok
    end
  end

  @doc """
  Runs git with the token and none of the host's config: `{:ok, output}` or
  `{:error, output}`. Options: `:cd`, `:env` (more variables).
  """
  def git(project, args, opts \\ []) do
    case System.cmd("git", args,
           cd: opts[:cd] || File.cwd!(),
           env: env(project) ++ (opts[:env] || []),
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, "git #{hd(args)}: " <> String.trim(output)}
    end
  end

  defp env(project) do
    base = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", "true"},
      {"SSH_ASKPASS", "true"}
    ]

    case token(project) do
      nil ->
        base

      token ->
        auth = Base.encode64("x-access-token:" <> token)

        base ++
          [
            {"GIT_CONFIG_COUNT", "1"},
            {"GIT_CONFIG_KEY_0", "http.extraHeader"},
            {"GIT_CONFIG_VALUE_0", "Authorization: Basic " <> auth}
          ]
    end
  end
end
