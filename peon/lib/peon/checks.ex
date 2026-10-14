defmodule Peon.Checks do
  @moduledoc """
  Compiles and tests every proposed changeset in the sandbox, one at a time.

  Steps stop at the first failure: deps, compile (warnings as errors), format,
  test. Results are stored on the changeset as
  `%{"steps" => [%{"name", "status", "duration_ms", "output"}]}`.

  Broadcasts on `Peon.PubSub` topic `"checks"`:
    * `{:check_step, changeset_id, step, "passed" | "failed"}`
    * `{:checked, changeset_id, "passed" | "failed", checks}`
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Peon.{Code, Repo, Sandbox, Store, Workspace}
  alias Peon.Store.Changeset

  @topic "checks"
  @output_limit 6_000
  @format_limit 40_000

  @steps [
    {"deps", "mix deps.get"},
    {"compile", "mix compile --warnings-as-errors"},
    {"format", "mix format --check-formatted"},
    {"test", "rm -f *_test.db *_test.db-*; mix test --warnings-as-errors"}
  ]

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

    {:ok, maybe_start(%{queue: :queue.from_list(pending), running: nil})}
  end

  @impl true
  def handle_info({:changeset, id, "proposed"}, state) do
    {:noreply, maybe_start(%{state | queue: :queue.in(id, state.queue)})}
  end

  def handle_info({ref, {id, status, checks}}, %{running: {id, ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(id, status, checks)
    {:noreply, maybe_start(%{state | running: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: {id, ref}} = state) do
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
    {:noreply, maybe_start(%{state | running: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_start(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, id}, queue} ->
        case Code.changeset(id) do
          {:ok, %{status: status}} when status in ["proposed", "checking"] ->
            Store.set_status(id, "checking", %{})
            task = Task.Supervisor.async_nolink(Peon.TaskSupervisor, fn -> run(id) end)
            %{state | queue: queue, running: {id, task.ref}}

          _ ->
            maybe_start(%{state | queue: queue})
        end
    end
  end

  defp maybe_start(state), do: state

  defp finish(id, status, checks) do
    case Store.set_status(id, status, checks) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.info("not recording check of #{id}: #{inspect(reason)}")
    end

    Phoenix.PubSub.broadcast(Peon.PubSub, @topic, {:checked, id, status, checks})
  end

  ## Running a check (in a task)

  defp run(id) do
    dir = Path.join(Application.fetch_env!(:peon, :data_dir), "checks/workspace")
    File.mkdir_p!(dir)
    Workspace.reset(dir, id)

    {status, steps} =
      Enum.reduce_while(@steps, {"passed", []}, fn {name, script}, {_, steps} ->
        {exit_status, output, duration} =
          Sandbox.run(dir, script, env: %{"MIX_ENV" => "test"}, name: "peon-check-#{id}-#{name}")

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

    {id, status, %{"steps" => steps}}
  end

  # Returns what `mix format` makes of each unformatted file, in full, so the
  # AI can resubmit it verbatim. Then restores the submitted files so the
  # workspace still matches the changeset's tree.
  defp format_feedback(dir, id) do
    tree = Code.tree(id)
    Sandbox.run(dir, "mix format", env: %{"MIX_ENV" => "test"}, name: "peon-format-#{id}")

    files =
      for {path, hash} <- tree,
          Path.extname(path) in [".ex", ".exs", ".heex"],
          original = Code.blob(hash),
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
