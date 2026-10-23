defmodule Burrow.Chat.KeepGoingTest do
  use ExUnit.Case, async: true

  alias Burrow.Chat.KeepGoing

  defp ticket(id, status), do: %{id: id, status: status, title: "Do #{id}"}

  test "unfinished tickets keep the agent going, the next one named" do
    tickets = [ticket("a", "in_progress"), ticket("b", "open"), ticket("c", "closed")]

    assert {:continue, text, run} = KeepGoing.after_turn(:ok, tickets, nil, KeepGoing.new_run())
    assert text =~ "2 unfinished tickets"
    assert text =~ "- a [in_progress] Do a"
    refute text =~ "Do c"
    assert run.stalls == 0
  end

  test "a queue that doesn't move in two turns stops the run" do
    tickets = [ticket("a", "open")]
    {:continue, _, run} = KeepGoing.after_turn(:ok, tickets, nil, KeepGoing.new_run())
    {:continue, _, run} = KeepGoing.after_turn(:ok, tickets, nil, run)

    assert {:stop, note} = KeepGoing.after_turn(:ok, tickets, nil, run)
    assert note =~ "1 unfinished ticket left"

    # A ticket closed in between is movement.
    {:continue, _, run} = KeepGoing.after_turn(:ok, tickets, nil, KeepGoing.new_run())
    moved = [ticket("a", "closed"), ticket("b", "open")]
    assert {:continue, _, %{stalls: 0}} = KeepGoing.after_turn(:ok, moved, nil, run)
  end

  test "with the queue done, a goal is judged; without one the turn is over" do
    done = [ticket("a", "closed")]

    assert :judge = KeepGoing.after_turn(:ok, done, "tests pass", KeepGoing.new_run())
    assert :done = KeepGoing.after_turn(:ok, done, nil, KeepGoing.new_run())
  end

  test "a failed or stopped turn ends the run, queue or not" do
    tickets = [ticket("a", "open")]

    assert :done = KeepGoing.after_turn(:error, tickets, "x", KeepGoing.new_run())
    assert :done = KeepGoing.after_turn(:interrupted, tickets, "x", KeepGoing.new_run())
  end

  test "a goal not met goes on with what is missing, for at most 20 turns" do
    run = KeepGoing.new_run()

    assert {:continue, text, %{goal_turns: 1}} =
             KeepGoing.after_verdict({:not_met, "2 tests fail"}, "tests pass", run)

    assert text =~ "2 tests fail"
    assert text =~ "Keep working toward it: tests pass"

    assert {:stop, "Peon stopped after 20 turns" <> _} =
             KeepGoing.after_turn(:ok, [], "tests pass", %{run | goal_turns: 20})

    assert {:met, "Goal met: 0 failures"} =
             KeepGoing.after_verdict({:met, "0 failures"}, "tests pass", run)
  end

  test "the judge's last verdict line counts, however it is dressed" do
    assert {:met, "mix test: 0 failures"} = KeepGoing.verdict("MET: mix test: 0 failures")
    assert {:not_met, "the page 404s"} = KeepGoing.verdict("**NOT MET**: the page 404s")

    assert {:met, "it renders"} =
             KeepGoing.verdict("Looking at it.\nNOT MET: no\nActually:\nMET - it renders")

    assert {:not_met, "Metrics look fine"} = KeepGoing.verdict("Metrics look fine")
  end
end
