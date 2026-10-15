defmodule Peon.Ship do
  @moduledoc """
  How a change gets from a chat to production, with no queue in front of main:

    1. `Peon.Checks` compiles and format-checks a submitted changeset. When it
       passes, it lands on main right away, unless it needs a human
       (`review_reasons/1`).
    2. `Peon.Verifier` runs the tests on main's tip. When they fail it finds
       the changeset that broke them and tells its chat to fix forward.
    3. Main's newest tested changeset moves the staging ref, and `Peon.Env`
       hot-loads it into the running staging app and watches its health. A
       human promotes staging to prod the same way.

  Peon reaches an agent by prompting its chat (`tell_chat/2`): failed tests,
  failed deploys and incidents from a running environment.
  """

  require Logger

  alias Peon.{Chat, Code, Project, Store}
  alias Peon.Store.Changeset
  alias PeonCore.Policy

  # Paths an AI changeset can't land by itself (project setting "review_paths").
  @review_paths ~w(mix.exs mix.lock config/** lib/*/accounts.ex lib/*/accounts/**
                   lib/*_web/user_auth.ex)

  def default_review_paths, do: @review_paths

  @doc "Why a passed changeset needs a human to land it; `[]` means it lands by itself."
  def review_reasons(%{author_kind: "human"}), do: []

  def review_reasons(cs) do
    settings = Project.settings()
    globs = settings["review_paths"] || @review_paths
    paths = for %{"path" => path} <- cs.files, Policy.matches?(path, globs), do: path

    if(settings["auto_land"] == false, do: ["auto-landing is off for this project"], else: []) ++
      if(paths == [], do: [], else: ["it changes #{Enum.join(paths, ", ")}"])
  end

  @doc """
  What happens to a changeset whose checks passed: `{:landed, main_id}`,
  `{:held, reasons}` or `{:not_landed, reason}` (e.g. `{:conflict, paths}`).
  """
  def after_checks(cs) do
    case review_reasons(cs) do
      [] ->
        case Store.land(cs.id, "peon") do
          {:ok, landed} -> {:landed, landed.id}
          {:error, reason} -> {:not_landed, reason}
        end

      reasons ->
        {:held, reasons}
    end
  end

  @doc "Submits the inverse of changeset `id` as `actor`; it lands once its checks pass."
  def revert(id, actor) do
    with {:ok, cs} <- Code.changeset(id) do
      before = if cs.parent_id, do: Code.tree(cs.parent_id), else: %{}

      files =
        for {path, _} <- Changeset.changes(cs) do
          case before[path] do
            nil -> %{"path" => path, "deleted" => true}
            hash -> %{"path" => path, "content" => Code.blob(hash)}
          end
        end

      Store.submit(%{
        parent: cs.id,
        intent: "Revert ##{cs.id}: #{cs.intent}",
        files: files,
        author: %{kind: :human, id: actor}
      })
    end
  end

  @doc "Prompts a chat's agent (starting it if needed) without waiting for it."
  def tell_chat(nil, _text), do: :ok

  def tell_chat(chat_id, text) do
    Task.Supervisor.start_child(Peon.TaskSupervisor, fn ->
      case Chat.send_message(chat_id, "[Peon] " <> text) do
        :ok -> :ok
        error -> Logger.warning("could not tell chat #{chat_id}: #{inspect(error)}")
      end
    end)

    :ok
  end
end
