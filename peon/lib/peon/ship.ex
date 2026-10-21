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

  A live-only project (setting `"envs" => "live"`, how new projects start)
  has no staging: the checks run the tests too, a human merges each passed
  changeset (`merge/2`), and main is what's live, so merging moves prod.
  `add_envs/1` turns it into a pipeline project, for good.
  """

  require Logger

  alias Peon.{Chat, Code, Env, Project, Store}
  alias Peon.Store.Changeset

  # Paths an AI changeset can't land by itself (project setting "review_paths"):
  # dependencies and config. Everything else, authentication included, lands
  # once its checks pass; main's tests and the health window guard it.
  @review_paths ~w(mix.exs mix.lock config/**)

  def default_review_paths, do: @review_paths

  @doc "Whether the project is live-only: main is live, there is no staging."
  def live_only?, do: Project.settings()["envs"] == "live"

  @doc "The environments the project uses: prod alone when it is live-only."
  def env_names do
    if live_only?(), do: Enum.reject(Env.names(), &(&1 == "staging")), else: Env.names()
  end

  @doc "Why a passed changeset needs a human to land it; `[]` means it lands by itself."
  def review_reasons(%{author_kind: "human"}), do: []

  def review_reasons(cs) do
    settings = Project.settings()

    if settings["envs"] == "live",
      do: ["merging it puts it live"],
      else: pipeline_reasons(cs, settings)
  end

  defp pipeline_reasons(cs, settings) do
    globs = settings["review_paths"] || @review_paths
    paths = for %{"path" => path} <- cs.files, Totem.Glob.matches?(path, globs), do: path

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
        # Only a human's changeset lands by itself on a live-only project; it
        # goes live on their say-so.
        actor = if live_only?(), do: cs.author_id, else: "peon"

        case merge(cs.id, actor) do
          {:ok, landed} -> {:landed, landed.id}
          {:error, reason} -> {:not_landed, reason}
        end

      reasons ->
        {:held, reasons}
    end
  end

  @doc """
  Lands passed changeset `id` on main as `actor`. On a live-only project that
  puts it live: prod moves to it, approved by `actor`. Returns the changeset
  now at main.
  """
  def merge(id, actor) do
    with {:ok, landed} <- Store.land(id, actor) do
      if live_only?(), do: put_live(id, landed, actor)
      {:ok, landed}
    end
  end

  defp put_live(id, landed, actor) do
    prod = Code.ref("prod")

    # Its tests ran in the checks. A rebased copy is a new tree: main's tests run on it.
    test = Enum.find((landed.checks || %{})["steps"] || [], &(&1["name"] == "test"))

    if (landed.id == id and test) && test["status"] == "passed",
      do: Store.set_verify(landed.id, %{"status" => "passed", "steps" => [test]})

    case Store.move_ref("prod", landed.id, (prod && prod.version) || 0, actor, approved_by: actor) do
      {:ok, _} -> :ok
      error -> Logger.warning("could not put ##{landed.id} live: #{inspect(error)}")
    end
  end

  @doc """
  Turns a live-only project into one with staging and prod. Both start at
  what is live now; from then on main's tested tip goes to staging first.
  """
  def add_envs(actor) do
    if live_only?() do
      Project.put_settings(%{"envs" => "pipeline", "envs_by" => actor})
      staging = Code.ref("staging")

      with %{changeset_id: live} <- Code.ref("prod"),
           true <- staging == nil or staging.changeset_id != live do
        Store.move_ref("staging", live, (staging && staging.version) || 0, actor)
      end
    end

    :ok
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
    Task.Supervisor.start_child(
      Peon.TaskSupervisor,
      Peon.Instance.bind(fn ->
        case Chat.send_message(chat_id, "[Peon] " <> text) do
          :ok -> :ok
          error -> Logger.warning("could not tell chat #{chat_id}: #{inspect(error)}")
        end
      end)
    )

    :ok
  end
end
