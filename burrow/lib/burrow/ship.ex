defmodule Burrow.Ship do
  @moduledoc """
  How a chat's change gets live, in a project with its own app:

    1. **Land** (`submit/3`, the agent's tool): the chat's edits become its
       draft in the project's history (`Totem.Repo`). The checks run in the
       chat's own agent container, on those very files: deps, compile with
       warnings as errors, the formatting of the changed files, the tests.
       Passed, it lands on main, merged line by line with what landed
       meanwhile; the same lines changed on both sides go back to the chat.
    2. **Check** (this process, one per project): every new main is tested,
       built and booted in prod mode in a throwaway container. When that
       fails, the newest change is taken out again (reverted) and its chat
       told.
    3. **Ship**: a person presses Ship (`ship/3`), or the project's
       `"auto_ship"` does it after a passed check; prod (or staging first,
       when the project has it) moves to main, and `Burrow.Env` loads it.

  Boards (`Burrow.Design`) skip the checks: a change that is only boards
  lands as it is, from the agent's submit or a person's `submit_design/3`,
  and main's check stays on the newest change with code. Boards never ship
  by themselves.

  Broadcasts on the project's `"ship"` topic: `{:draft, chat_id, status}`,
  `{:check_step, chat_id, step, status}` and `{:main_check, run}`; and on
  `"refs"`: `{:ref_moved, name, change_id}`.
  """

  use GenServer

  require Logger

  alias Burrow.{Chat, Design, Projects, Runs, Sandbox, Workspace}
  alias Totem.Repo

  @forbidden ~w(config/runtime.exs AGENTS.md rel/** priv/peon/anonymize.exs)
  @formattable ~w(.ex .exs .heex)
  @output_limit 6_000

  def start_link(project),
    do: GenServer.start_link(__MODULE__, project, name: Burrow.Cell.via(project.id, __MODULE__))

  def subscribe(project_id), do: Projects.subscribe(project_id, "ship")

  @doc "Whether the project has staging in front of prod."
  def staging?(project), do: project.envs == "pipeline"

  @doc "The last main check: a `Burrow.Runs` row, or nil."
  def main_check(project), do: Runs.last(project.id, "check", "main")

  ## Land

  @doc """
  The agent submits its chat's edits: `{text for the agent, failed?}`. Boards
  alone (`Burrow.Design`) land without the checks.
  """
  def submit(project, chat_id, intent) do
    repo = Projects.repo_dir(project)
    dir = Chat.workspace_dir(project, chat_id)
    {base, files} = Workspace.changes(dir)
    opts = [intent: intent, kind: "ai", author: chat_id, policy: [forbidden_paths: @forbidden]]

    case Repo.put_draft(repo, chat_id, base, files, opts) do
      {:ok, draft} ->
        if Design.only?(draft.files) do
          project |> land(chat_id) |> landed(:design)
        else
          draft(project, chat_id, status: "checking", checks: %{})
          {status, steps} = check(project, chat_id, draft)
          draft(project, chat_id, status: status, checks: %{"steps" => steps})

          if status == "passed",
            do: project |> land(chat_id) |> landed(:code),
            else: {failed(steps), true}
        end

      {:error, :no_changes} ->
        {"There are no changes in /app to submit.", true}

      {:error, {:policy, violations}} ->
        {"Rejected: " <> Enum.map_join(violations, "\n", & &1.reason), true}

      {:error, reason} ->
        {"Rejected: #{inspect(reason)}", true}
    end
  end

  # In the chat's agent container, on its own files, stopping at the first failure.
  defp check(project, chat_id, draft) do
    format =
      for {path, hash} <- draft.files,
          hash != :deleted,
          Path.extname(path) in @formattable,
          do: quote_arg(path)

    steps = [
      # The preview fetches into the same deps/ when it starts: try again after it.
      {"deps", "mix deps.get || (sleep 20 && mix deps.get) || (sleep 40 && mix deps.get)"},
      {"compile", "mix compile --warnings-as-errors"},
      {"format",
       if(format == [],
         do: "true",
         else: "mix format --check-formatted " <> Enum.join(format, " ")
       )},
      {"test", "rm -f *_test.db *_test.db-*; mix test"}
    ]

    container = Chat.agent_name(project, chat_id)
    # Tests run the checks without a container.
    exec = Application.get_env(:burrow, :check_runner, &Sandbox.exec/3)

    Enum.reduce_while(steps, {"passed", []}, fn {name, script}, {_, done} ->
      started = System.monotonic_time(:millisecond)
      {output, code} = exec.(container, script, env: %{"MIX_ENV" => "test"})
      status = if code == 0, do: "passed", else: "failed"
      Projects.broadcast(project.id, "ship", {:check_step, chat_id, name, status})

      step = %{
        "name" => name,
        "status" => status,
        "duration_ms" => System.monotonic_time(:millisecond) - started,
        "output" => if(code == 0, do: "", else: trim(output))
      }

      if code == 0,
        do: {:cont, {"passed", done ++ [step]}},
        else: {:halt, {"failed", done ++ [step]}}
    end)
  end

  @doc """
  A person lands the chat's boards: when all it changed is under design/,
  that goes to main as it is, without the checks. `{:ok, change}`, or
  `{:error, :not_design_only | {:conflict, paths} | :no_changes}`.
  """
  def submit_design(project, chat_id, actor) do
    {base, files} = Workspace.changes(Chat.workspace_dir(project, chat_id))
    names = Enum.map(files, fn {path, _} -> String.replace_prefix(path, "design/", "") end)

    opts = [
      intent: "Boards: " <> Enum.join(names, ", "),
      kind: "human",
      author: actor,
      policy: [forbidden_paths: @forbidden]
    ]

    with true <- Design.only?(files) || {:error, :not_design_only},
         {:ok, _draft} <- Repo.put_draft(Projects.repo_dir(project), chat_id, base, files, opts) do
      land(project, chat_id)
    end
  end

  defp land(project, chat_id) do
    repo = Projects.repo_dir(project)

    case Repo.land(repo, chat_id, chat_id) do
      {:ok, change} ->
        # The folder now starts from the landed change, with what others landed.
        Workspace.rebase(repo, Chat.workspace_dir(project, chat_id), change.id)
        Projects.broadcast(project.id, "ship", {:draft, chat_id, "landed"})
        moved(project, "main", change.id)
        {:ok, change}

      {:error, {:conflict, _paths}} = error ->
        draft(project, chat_id, status: "open")
        Workspace.rebase(repo, Chat.workspace_dir(project, chat_id), Repo.ref(repo, "main"))
        error

      error ->
        error
    end
  end

  defp landed({:ok, change}, :code),
    do:
      {"It landed on main as ##{change.id}. Main is now tested, built and booted in prod " <>
         "mode; if that fails you get a message here. Then the user ships it.", false}

  defp landed({:ok, change}, :design),
    do: {"The boards landed on main as ##{change.id}. Boards are never shipped.", false}

  defp landed({:error, {:conflict, paths}}, _kind),
    do:
      {"""
       It did not land: another chat changed the same lines of #{Enum.join(paths, ", ")}. \
       /app is now on main's latest version; your version of those files is kept and \
       main's is in .peon/main/<path>. Merge main's changes into your files and submit again.\
       """, true}

  defp landed({:error, :no_changes}, _kind), do: {"Main already has these changes.", false}

  defp draft(project, chat_id, fields) do
    Repo.update_draft(Projects.repo_dir(project), chat_id, fields)

    if status = fields[:status],
      do: Projects.broadcast(project.id, "ship", {:draft, chat_id, status})
  end

  defp failed(steps) do
    step = List.last(steps)

    """
    Checks FAILED at step "#{step["name"]}":

    #{step["output"]}

    Fix this in /app and call submit_changeset again.\
    """
  end

  ## Ship, revert

  @doc "Moves prod (a person's say-so) to main's change `id`."
  def ship(project, id, actor) do
    repo = Projects.repo_dir(project)
    current = Repo.ref(repo, "prod")

    with :ok <- Repo.move_ref(repo, "prod", id, current) do
      Logger.info("#{project.slug}: #{actor} ships ##{id}")
      Projects.broadcast(project.id, "refs", {:ref_moved, "prod", id})
    end
  end

  @doc "Takes change `id` out of main again, as a new change."
  def revert(project, id, actor) do
    with {:ok, change} <- Repo.revert(Projects.repo_dir(project), id, actor) do
      moved(project, "main", change.id)
      {:ok, change}
    end
  end

  @doc "An environment runs `id` healthily: staging passes it on to prod when shipping is automatic."
  def healthy(project, "staging", id) do
    if Projects.settings(project)["auto_ship"] == true, do: ship(project, id, "auto-ship")
    :ok
  end

  def healthy(_project, _env, _id), do: :ok

  @doc "Prompts a chat's agent (starting it if needed) without waiting for it."
  def tell_chat(_project_id, nil, _text), do: :ok

  def tell_chat(project_id, chat_id, text) do
    # Without running projects (tests) there are no agents to tell.
    if Application.get_env(:burrow, :start_cells, true),
      do: start_telling(project_id, chat_id, text)

    :ok
  end

  defp start_telling(project_id, chat_id, text) do
    Task.Supervisor.start_child(Burrow.TaskSupervisor, fn ->
      with %{} = project <- Projects.get(project_id),
           :ok <- Chat.send_message(project, chat_id, "[Peon] " <> text) do
        :ok
      else
        error -> Logger.warning("could not tell chat #{chat_id}: #{inspect(error)}")
      end
    end)

    :ok
  end

  defp moved(project, ref, id) do
    Projects.broadcast(project.id, "refs", {:ref_moved, ref, id})
    if ref == "main", do: GenServer.cast(Burrow.Cell.via(project.id, __MODULE__), :next)
  end

  ## Check main

  @impl true
  def init(project) do
    send(self(), :next)
    {:ok, %{project: project, task: nil}}
  end

  @impl true
  def handle_cast(:next, state), do: {:noreply, next(state)}

  @impl true
  def handle_info(:next, state), do: {:noreply, next(state)}

  def handle_info({ref, {run, status, detail}}, %{task: {ref, _tip}} = state) do
    Process.demonitor(ref, [:flush])
    run = Runs.finish(run, status: status, detail: detail)
    Projects.broadcast(state.project.id, "ship", {:main_check, run})

    if status == "passed",
      do: advance(state.project, run.change_id),
      else: blame(state.project, run)

    {:noreply, next(%{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: {ref, tip}} = state) do
    Logger.error("#{state.project.slug}: checking main ##{tip} crashed: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp next(%{task: nil, project: project} = state) do
    tip = code_tip(Projects.repo_dir(project))
    last = main_check(project)

    if tip && (last == nil or last.change_id != tip or last.status == "running") do
      run = Runs.start(project.id, "check", "main", tip)
      Projects.broadcast(project.id, "ship", {:main_check, run})

      task =
        Task.Supervisor.async_nolink(Burrow.TaskSupervisor, fn -> check_main(project, run) end)

      %{state | task: {task.ref, tip}}
    else
      state
    end
  end

  defp next(state), do: state

  # Main's newest change that isn't boards only: boards need no check.
  defp code_tip(repo), do: code_tip(repo, Repo.ref(repo, "main"))

  defp code_tip(_repo, nil), do: nil

  defp code_tip(repo, id) do
    case Repo.change(repo, id) do
      %{files: files, parent: parent} ->
        if Design.only?(files), do: code_tip(repo, parent), else: id

      nil ->
        nil
    end
  end

  @doc false
  # Tests, then a prod build that must boot and answer /health, in a fresh
  # container on main's tip.
  def check_main(project, run) do
    repo = Projects.repo_dir(project)
    dir = Path.join(Projects.dir(project), "main-check")
    Workspace.reset(repo, dir, run.change_id)

    prod = %{
      "MIX_ENV" => "prod",
      "DATABASE_PATH" => "/tmp/check.db",
      "SECRET_KEY_BASE" => String.duplicate("c", 64),
      "PHX_HOST" => "localhost",
      "PORT" => "4000"
    }

    steps = [
      {"test", %{"MIX_ENV" => "test"},
       Sandbox.unlock_deps() <> "mix deps.get && rm -f *_test.db *_test.db-*; mix test"},
      {"build", prod,
       "mix deps.get --only prod && mix compile && mix assets.setup && mix assets.deploy"},
      {"boot", prod,
       "mix ecto.migrate && (mix phx.server > /tmp/boot.log 2>&1 &) && " <>
         "for i in $(seq 60); do curl -sf -o /dev/null http://localhost:4000/health && exit 0; sleep 2; done; " <>
         "cat /tmp/boot.log; exit 1"}
    ]

    Enum.reduce_while(steps, {run, "passed", ""}, fn {name, env, script}, acc ->
      {code, output, _ms} =
        Sandbox.run(dir, script, project: project.slug, env: env, timeout: :timer.minutes(20))

      if code == 0,
        do: {:cont, acc},
        else: {:halt, {run, "failed", "#{name} failed:\n\n" <> trim(to_string(output))}}
    end)
  end

  # Main passed: on to staging, or to prod when shipping is automatic.
  defp advance(project, tip) do
    repo = Projects.repo_dir(project)

    cond do
      staging?(project) ->
        with :ok <- Repo.move_ref(repo, "staging", tip, Repo.ref(repo, "staging")),
             do: Projects.broadcast(project.id, "refs", {:ref_moved, "staging", tip})

      Projects.settings(project)["auto_ship"] == true ->
        ship(project, tip, "auto-ship")

      true ->
        :ok
    end
  end

  @doc false
  # Main failed: the newest change, a chat's, comes out again and its chat is told.
  def blame(project, run) do
    repo = Projects.repo_dir(project)

    with %{draft: chat_id} = change when chat_id != nil <- Repo.change(repo, run.change_id),
         true <- Repo.ref(repo, "main") == change.id,
         {:ok, _} <- revert(project, change.id, "peon") do
      main = %{"name" => "main", "status" => "failed", "output" => run.detail}

      Repo.update_draft(repo, chat_id,
        status: "failed",
        change: nil,
        checks: %{"steps" => [main]}
      )

      Projects.broadcast(project.id, "ship", {:draft, chat_id, "failed"})

      tell_chat(project.id, chat_id, """
      Your change ##{change.id} ("#{change.intent}") landed, but main did not pass in prod \
      mode, so it was taken out again. /app still has your version. Fix it and submit again.

      #{run.detail}\
      """)
    end
  end

  @doc false
  # Check output, cut to its errors, within the size the agent gets back.
  def trim(output) do
    lines = String.split(output, "\n")

    lines =
      case Enum.find_index(lines, &(&1 =~ ~r/error|warning|failure|\*\* \(/i)) do
        nil -> Enum.take(lines, -80)
        index -> Enum.drop(lines, max(index - 2, 0))
      end

    text = Enum.join(lines, "\n")

    if byte_size(text) > @output_limit,
      do: binary_part(text, 0, @output_limit) <> "\n...",
      else: text
  end

  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"
end
