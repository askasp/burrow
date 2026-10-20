defmodule Peon.Git do
  @moduledoc """
  The git repo of a repo project (`Peon.Source`). Peon keeps one bare mirror
  of it in `<data_dir>/repo.git`, fetched before each new chat, and gives
  every chat its own clone of that mirror on branch `peon/<chat id>`. The
  clone is self-contained, so the agent can use git in its container.

  git runs without the host's config or credentials: the only way in is the
  project's `GITHUB_TOKEN` secret, passed in the environment as an HTTP
  header, never written to disk. Public repos need no token.

  As a child of the application it records the project on first boot and
  clears out containers and repo previews a previous run left behind, like
  `Peon.Bootstrap`.
  """

  require Logger

  alias Peon.{Project, Repo, Sandbox, Secrets, Source}

  @token "GITHUB_TOKEN"

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    Sandbox.remove_all()
    Peon.Chat.stop_left_behind()

    if Project.get() == nil do
      Repo.insert!(%Project{
        slug: Application.fetch_env!(:peon, :project_slug),
        name: Application.fetch_env!(:peon, :project_name),
        settings: %{"repo_url" => Source.repo().url}
      })
    end

    Peon.Chats.create_first()
    :ignore
  end

  def mirror_dir, do: Path.join(Application.fetch_env!(:peon, :data_dir), "repo.git")

  @doc """
  Clones the repo into the mirror, or fetches it. One at a time, so chats
  starting together don't clone twice.
  """
  def sync do
    :global.trans({__MODULE__, :mirror}, fn ->
      dir = mirror_dir()

      if File.dir?(dir) do
        with {:ok, _} <- git(["fetch", "--prune", "origin"], cd: dir), do: :ok
      else
        tmp = dir <> ".tmp"
        File.rm_rf!(tmp)

        with {:ok, _} <- git(["clone", "--bare", Source.repo().url, tmp]),
             {:ok, _} <-
               git(["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"], cd: tmp) do
          File.rename!(tmp, dir)
          :ok
        end
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, output} ->
        if needs_token?(output), do: request_token(nil)
        {:error, output}
    end
  end

  @doc "Whether git failed for want of the token: no token is set and access was refused."
  def needs_token?(output),
    do:
      token() == nil and
        output =~ ~r/auth|could not read|not found|does not exist|denied|403|404/i

  @doc "Asks the user for the token; `chat_id` is told once it is set."
  def request_token(chat_id) do
    Secrets.request(
      @token,
      "Lets Peon clone #{Source.repo().url} and open PRs. GitHub, Settings, " <>
        "Developer settings, fine-grained token for this repo: Contents and " <>
        "Pull requests, read and write.",
      chat_id
    )
  end

  def token, do: Secrets.env_value(@token)

  def checked_out?(dir), do: File.dir?(Path.join(dir, ".git"))

  @doc """
  Makes `dir` a clone of the mirror on a new branch `peon/<chat_id>` from the
  repo's main branch, with `origin` pointing at the real repo.
  """
  def checkout(dir, chat_id) do
    branch = Source.repo().branch
    File.mkdir_p!(Path.dirname(dir))
    File.rm_rf!(dir)

    with :ok <- sync(),
         {:ok, _} <- git(["clone", "--local", "--branch", branch, mirror_dir(), dir]),
         {:ok, _} <- git(["checkout", "-b", "peon/#{chat_id}"], cd: dir),
         {:ok, _} <- git(["remote", "set-url", "origin", Source.repo().url], cd: dir) do
      :ok
    end
  end

  @doc """
  Runs git with the token and none of the host's config: `{:ok, output}` or
  `{:error, output}`. Options: `:cd`, `:env` (more variables).
  """
  def git(args, opts \\ []) do
    case System.cmd("git", args,
           cd: opts[:cd] || File.cwd!(),
           env: env() ++ (opts[:env] || []),
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, "git #{hd(args)}: " <> String.trim(output)}
    end
  end

  defp env do
    base = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", "true"},
      {"SSH_ASKPASS", "true"}
    ]

    case token() do
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
