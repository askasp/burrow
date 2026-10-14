defmodule PeonCore.Policy do
  @moduledoc """
  Deterministic changeset rules, applied at submit and again before any ref move.

  Rules checked here (static, no compilation needed):
    1. AI changesets may not touch forbidden paths.
    2. Changes to restart paths are flagged `restart_required`.
    3. Existing migrations may never be edited or deleted.
    4. New migrations with destructive operations need human approval.
    5. Content matching secret patterns is rejected.

  Rule 6 (`@vsn` requires `code_change/3`) runs in the check sandbox, and rule 7
  (prod needs approval) runs at ref move.
  """

  alias PeonCore.Tree

  @default_settings %{
    restart_paths: [
      "mix.exs",
      "mix.lock",
      "config/**",
      "lib/*/application.ex",
      "lib/*_web/endpoint.ex"
    ],
    forbidden_paths: [
      "config/runtime.exs",
      "AGENTS.md",
      "rel/**",
      "priv/peon/anonymize.exs"
    ],
    migration_paths: ["priv/repo/migrations/*.exs"]
  }

  @destructive ~r/\b(remove|rename|drop|drop_if_exists|modify|execute)\b\s*[\(\s]/

  @secret_patterns [
    {"Stripe live key", ~r/\b[sr]k_live_[0-9A-Za-z]{10,}/},
    {"Anthropic API key", ~r/\bsk-ant-[0-9A-Za-z_-]{10,}/},
    {"AWS access key", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"GitHub token", ~r/\bgh[pousr]_[0-9A-Za-z]{30,}/},
    {"Slack token", ~r/\bxox[abposr]-[0-9A-Za-z-]{10,}/},
    {"private key", ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/}
  ]

  @type file :: {String.t(), String.t() | :deleted}
  @type violation :: %{rule: atom(), path: String.t(), reason: String.t()}
  @type flags :: %{restart_required: boolean(), destructive_migrations: [String.t()]}

  def default_settings, do: @default_settings

  @doc """
  Checks `files` (path => new content or `:deleted`) against `base_tree`.

  Options:
    * `:author` - `:ai` or `:human` (default `:ai`)
    * `:approve_destructive` - human confirmation for destructive migrations
    * `:settings` - overrides for `default_settings/0`
  """
  @spec check([file()], Tree.t(), keyword()) :: {:ok, flags()} | {:error, [violation()]}
  def check(files, base_tree, opts \\ []) do
    author = Keyword.get(opts, :author, :ai)
    settings = Map.merge(@default_settings, Map.new(Keyword.get(opts, :settings, [])))
    approved? = Keyword.get(opts, :approve_destructive, false) and author == :human

    destructive =
      for {path, content} <- files,
          content != :deleted,
          new_migration?(path, base_tree, settings),
          Regex.match?(@destructive, content),
          do: path

    violations =
      Enum.flat_map(files, fn {path, content} ->
        forbidden(path, author, settings) ++
          edited_migration(path, base_tree, settings) ++ secrets(path, content)
      end) ++
        if(approved?, do: [], else: Enum.map(destructive, &destructive_violation/1))

    case violations do
      [] ->
        {:ok,
         %{
           restart_required: Enum.any?(files, &matches?(elem(&1, 0), settings.restart_paths)),
           destructive_migrations: destructive
         }}

      violations ->
        {:error, violations}
    end
  end

  @doc "Matches `path` against glob patterns where `*` stays within a segment and `**` spans segments."
  @spec matches?(String.t(), [String.t()]) :: boolean()
  def matches?(path, globs), do: Enum.any?(globs, &Regex.match?(glob_regex(&1), path))

  defp forbidden(path, :ai, settings) do
    if matches?(path, settings.forbidden_paths) do
      [
        %{
          rule: :forbidden_path,
          path: path,
          reason: "#{path} is a forbidden path for AI changesets"
        }
      ]
    else
      []
    end
  end

  defp forbidden(_path, _author, _settings), do: []

  defp edited_migration(path, base_tree, settings) do
    if matches?(path, settings.migration_paths) and Map.has_key?(base_tree, path) do
      [
        %{
          rule: :edited_migration,
          path: path,
          reason: "#{path} is an existing migration; add a new migration instead"
        }
      ]
    else
      []
    end
  end

  defp new_migration?(path, base_tree, settings) do
    matches?(path, settings.migration_paths) and not Map.has_key?(base_tree, path)
  end

  defp destructive_violation(path) do
    %{
      rule: :destructive_migration,
      path: path,
      reason:
        "#{path} contains remove/rename/drop/modify/execute; migrations must be additive " <>
          "unless a human approves them"
    }
  end

  defp secrets(_path, :deleted), do: []

  defp secrets(path, content) do
    for {name, regex} <- @secret_patterns, Regex.match?(regex, content) do
      %{rule: :secret, path: path, reason: "#{path} contains what looks like a #{name}"}
    end
  end

  defp glob_regex(glob) do
    body =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*", "\0")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\0", ".*")

    Regex.compile!("^" <> body <> "$")
  end
end
