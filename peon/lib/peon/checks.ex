defmodule Peon.Checks do
  @moduledoc """
  The gate in front of main: compiles and format-checks every proposed
  changeset in the sandbox. Several run at once, each in its own warm
  workspace (`:check_slots`), and a changeset that passes lands on main right
  away (`Peon.Ship.after_checks/1`). Tests run after landing, on main
  (`Peon.Verifier`).

  Steps stop at the first failure: deps, compile (warnings as errors), format
  (of the files the changeset touches, so older files never block a change),
  and on a live-only project test (`Peon.Ship.live_only?/0`).
  Results are stored on the changeset as
  `%{"steps" => [%{"name", "status", "duration_ms", "output"}]}`.

  Broadcasts on `Peon.PubSub` topic `"checks"`:
    * `{:check_step, changeset_id, step, "passed" | "failed"}`
    * `{:checked, changeset_id, "passed" | "failed", checks, outcome}`, where
      outcome is `nil` (failed) or what `Peon.Ship.after_checks/1` returned
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Peon.{Code, Repo, Sandbox, Ship, Store, Verifier, Workspace}
  alias Peon.Store.Changeset

  @topic "checks"
  @output_limit 6_000
  @format_limit 40_000

  @formattable [".ex", ".exs", ".heex"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Peon.PubSub, @topic)

  @doc "Trims check output to its errors, within the size the AI gets back."
  def trim_output(output) do
    lines = String.split(output, "\n")

    lines =
      case Enum.find_index(lines, &(&1 =~ ~r/error|warning|failure|\*\* \(/i)) do
        nil -> Enum.take(lines, -80)
        index -> Enum.drop(lines, max(index - 2, 0))
      end

    lines |> Enum.join("\n") |> cap()
  end

  defp cap(text, limit \\ @output_limit)

  defp cap(text, limit) when byte_size(text) > limit,
    do: binary_part(text, 0, limit) <> "\n... (output truncated)"

  defp cap(text, _limit), do: text

  ## Server

  @impl true
  def init(_opts) do
    Store.subscribe()

    pending =
      Repo.all(
        from c in Changeset,
          where: c.status in ["proposed", "checking"],
          order_by: c.id,
          select: c.id
      )

    slots = Enum.to_list(1..Application.get_env(:peon, :check_slots, 2))
    {:ok, maybe_start(%{queue: :queue.from_list(pending), running: %{}, free: slots})}
  end

  @impl true
  def handle_info({:changeset, id, "proposed"}, state) do
    {:noreply, maybe_start(%{state | queue: :queue.in(id, state.queue)})}
  end

  def handle_info({ref, {id, status, checks}}, %{running: running} = state)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    finish(id, status, checks)
    {:noreply, state |> done(ref) |> maybe_start()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state)
      when is_map_key(running, ref) do
    {id, _slot} = running[ref]
    Logger.error("check of changeset #{id} crashed: #{inspect(reason)}")

    checks = %{
      "steps" => [
        %{
          "name" => "check",
          "status" => "failed",
          "output" => "check crashed: #{inspect(reason)}"
        }
      ]
    }

    finish(id, "failed", checks)
    {:noreply, state |> done(ref) |> maybe_start()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp done(state, ref) do
    {{_id, slot}, running} = Map.pop!(state.running, ref)
    %{state | running: running, free: [slot | state.free]}
  end

  defp maybe_start(%{free: [slot | free]} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, id}, queue} ->
        case Code.changeset(id) do
          {:ok, %{status: status}} when status in ["proposed", "checking"] ->
            Store.set_status(id, "checking", %{})
            task = Task.Supervisor.async_nolink(Peon.TaskSupervisor, fn -> run(id, slot) end)
            running = Map.put(state.running, task.ref, {id, slot})
            maybe_start(%{state | queue: queue, running: running, free: free})

          _ ->
            maybe_start(%{state | queue: queue})
        end
    end
  end

  defp maybe_start(state), do: state

  defp finish(id, status, checks) do
    outcome =
      case Store.set_status(id, status, checks) do
        {:ok, %{status: "passed"} = cs} ->
          Ship.after_checks(cs)

        {:ok, _} ->
          nil

        {:error, reason} ->
          Logger.info("not recording check of #{id}: #{inspect(reason)}")
          nil
      end

    Phoenix.PubSub.broadcast(Peon.PubSub, @topic, {:checked, id, status, checks, outcome})
  end

  ## Running a check (in a task)

  defp run(id, slot) do
    dir = Path.join(Application.fetch_env!(:peon, :data_dir), "checks/slot-#{slot}")
    format = Enum.map_join(formattable(id), " ", &shell_quote/1)

    steps = [
      {"deps", "mix deps.get"},
      {"compile", "mix compile --warnings-as-errors"},
      {"format", if(format == "", do: "true", else: "mix format --check-formatted " <> format)}
    ]

    # Live-only projects have no staging to catch a failing suite after landing.
    steps = if Ship.live_only?(), do: steps ++ [Verifier.test_step()], else: steps

    {status, steps} = run_steps(dir, id, steps)
    {id, status, %{"steps" => steps}}
  end

  # The files a changeset writes that `mix format` handles.
  defp formattable(id) do
    {:ok, cs} = Code.changeset(id)

    for %{"path" => path, "hash" => hash} <- cs.files,
        hash,
        Path.extname(path) in @formattable,
        do: path
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"

  @doc """
  Resets `dir` to changeset `id` and runs `steps` (`{name, script}`) in the
  sandbox until one fails. Returns `{"passed" | "failed", steps}`.
  """
  def run_steps(dir, id, steps) do
    File.mkdir_p!(dir)
    Workspace.reset(dir, id)

    Enum.reduce_while(steps, {"passed", []}, fn {name, script}, {_, steps} ->
      {exit_status, output, duration} =
        Sandbox.run(dir, script,
          env: %{"MIX_ENV" => "test"},
          name: "peon-check-#{id}-#{name}-#{System.unique_integer([:positive])}"
        )

      passed? = exit_status == 0
      output = if !passed? and name == "format", do: format_feedback(dir, id), else: output

      step = %{
        "name" => name,
        "status" => if(passed?, do: "passed", else: "failed"),
        "duration_ms" => duration,
        "output" =>
          cond do
            passed? -> ""
            name == "format" -> cap(output, @format_limit)
            true -> trim_output(output)
          end
      }

      Phoenix.PubSub.broadcast(Peon.PubSub, @topic, {:check_step, id, name, step["status"]})

      if passed?,
        do: {:cont, {"passed", steps ++ [step]}},
        else: {:halt, {"failed", steps ++ [step]}}
    end)
  end

  # Returns what `mix format` makes of each unformatted file, in full, so the
  # AI can resubmit it verbatim. Then restores the submitted files so the
  # workspace still matches the changeset's tree.
  defp format_feedback(dir, id) do
    tree = Code.tree(id)
    paths = formattable(id)
    script = "mix format " <> Enum.map_join(paths, " ", &shell_quote/1)
    Sandbox.run(dir, script, env: %{"MIX_ENV" => "test"}, name: "peon-format-#{id}")

    files =
      for path <- paths,
          original = Code.blob(tree[path]),
          {:ok, formatted} = File.read(Path.join(dir, path)),
          formatted != original do
        File.write!(Path.join(dir, path), original)
        "=== #{path} ===\n" <> formatted
      end

    "These files are not formatted the way `mix format` formats them. Resubmit each one " <>
      "with content set to exactly the text below (between its === header and the next):\n\n" <>
      Enum.join(files, "\n")
  end
end
