defmodule Peon.Verifier do
  @moduledoc """
  Tests main after changes land. It runs the suite on main's tip, so changes
  that land during a run are batched into the next one. When the tip fails,
  it bisects between the last passing changeset and the tip to find the one
  that broke the tests (`plan/1`), and tells that changeset's chat to fix it
  forward.

  When main's tip passes, the staging ref moves to it (unless that changeset
  already failed a staging deploy), and `Peon.Env` deploys it.

  Results are stored with `Peon.Store.set_verify/2`, which broadcasts
  `{:verified, id, status}` on the store topic.
  """

  use GenServer

  require Logger

  alias Peon.{Checks, Code, Env, Ship, Store}

  @test {"test", "rm -f *_test.db *_test.db-*; mix test --warnings-as-errors"}
  @steps [{"deps", "mix deps.get"}, @test]

  @doc "The step that runs the suite, for `Peon.Checks` on live-only projects."
  def test_step, do: @test

  # How far back from main's tip to look for the last passing changeset.
  @max_chain 200

  def start_link(instance),
    do: GenServer.start_link(__MODULE__, instance, name: Peon.Instance.via(instance, __MODULE__))

  @doc """
  What to do next, given main's history from the last passing changeset to
  the tip, oldest first, as `{id, verify_status, blamed?}`:
  `{:test, id}`, `{:blame, id}` or `:idle`.
  """
  def plan([]), do: :idle

  def plan(chain) do
    {tip, tip_status, _} = List.last(chain)

    case tip_status do
      nil -> {:test, tip}
      "passed" -> :idle
      "failed" -> narrow(chain)
    end
  end

  # The culprit is the first failure right after a pass. Test the middle of
  # the untested stretch between the last pass and the first failure after it.
  defp narrow(chain) do
    indexed = Enum.with_index(chain)

    last_pass =
      Enum.reduce(indexed, -1, fn {{_, status, _}, i}, acc ->
        if status == "passed", do: i, else: acc
      end)

    {{first_fail, _, blamed?}, fail_index} =
      Enum.find(indexed, fn {{_, status, _}, i} -> i > last_pass and status == "failed" end)

    cond do
      fail_index == last_pass + 1 and blamed? -> :idle
      fail_index == last_pass + 1 -> {:blame, first_fail}
      true -> {:test, chain |> Enum.at(div(last_pass + fail_index, 2)) |> elem(0)}
    end
  end

  @doc "The changeset blamed for main's failing tests, while main is red."
  def culprit do
    Enum.find_value(chain(), fn
      {id, "failed", true} -> with {:ok, cs} <- Code.changeset(id), do: cs
      _ -> nil
    end)
  end

  ## Server

  @impl true
  def init(instance) do
    Peon.Instance.put(instance)
    Store.subscribe()
    send(self(), :next)
    {:ok, %{running: nil}}
  end

  @impl true
  def handle_info({:ref_moved, "main", _id, _version}, state), do: {:noreply, next(state)}
  def handle_info(:next, state), do: {:noreply, next(state)}

  def handle_info({ref, {id, status, steps}}, %{running: {id, ref}} = state) do
    Process.demonitor(ref, [:flush])
    Store.set_verify(id, %{"status" => status, "steps" => steps})
    {:noreply, next(%{state | running: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: {id, ref}} = state) do
    Logger.error("testing changeset #{id} on main crashed: #{inspect(reason)}")
    Process.send_after(self(), :next, :timer.seconds(30))
    {:noreply, %{state | running: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp next(%{running: nil} = state) do
    chain = chain()

    case plan(chain) do
      {:test, id} ->
        dir = Path.join(Peon.Instance.fetch!(:data_dir), "checks/verify")

        task =
          Task.Supervisor.async_nolink(
            Peon.TaskSupervisor,
            Peon.Instance.bind(fn ->
              {status, steps} = Checks.run_steps(dir, id, @steps)
              {id, status, steps}
            end)
          )

        %{state | running: {id, task.ref}}

      {:blame, id} ->
        blame(id)
        next(state)

      :idle ->
        with {tip, "passed", _} <- List.last(chain), do: stage(tip)
        state
    end
  end

  defp next(state), do: state

  defp chain do
    case Code.ref("main") do
      nil -> []
      main -> walk(main.changeset_id, [], @max_chain)
    end
  end

  defp walk(nil, acc, _left), do: acc
  defp walk(_id, acc, 0), do: acc

  defp walk(id, acc, left) do
    {:ok, cs} = Code.changeset(id)
    # The import is the baseline: it is the template, tested upstream.
    status = (cs.verify || %{})["status"] || if(cs.parent_id == nil, do: "passed")
    acc = [{cs.id, status, (cs.verify || %{})["blamed"] == true} | acc]
    if status == "passed", do: acc, else: walk(cs.parent_id, acc, left - 1)
  end

  defp blame(id) do
    {:ok, cs} = Code.changeset(id)
    Store.set_verify(id, Map.put(cs.verify, "blamed", true))
    failed = Enum.find(cs.verify["steps"] || [], &(&1["status"] == "failed")) || %{}

    Ship.tell_chat(cs.conversation_id, """
    Main's tests fail since your changeset ##{cs.id} ("#{cs.intent}") landed. Nothing \
    deploys until main is green again, so fix it forward now: your workspace is up to \
    date with main. Run the failing tests, fix them and submit.

    #{failed["output"]}\
    """)
  end

  # Main's tip passed: deploy it to staging, unless it already failed there.
  # A live-only project has no staging; merging moved prod already.
  defp stage(tip) do
    staging = Code.ref("staging")

    cond do
      Ship.live_only?() ->
        :ok

      staging && staging.changeset_id == tip ->
        :ok

      Env.failed_deploy?("staging", tip) ->
        :ok

      true ->
        version = if staging, do: staging.version, else: 0

        case Store.move_ref("staging", tip, version, "peon") do
          {:ok, _} -> :ok
          error -> Logger.warning("could not move staging: #{inspect(error)}")
        end
    end
  end
end
