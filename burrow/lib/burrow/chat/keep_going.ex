defmodule Burrow.Chat.KeepGoing do
  @max_goal_turns 20
  @max_stalls 2

  @moduledoc """
  Whether the agent keeps going when its turn is over, instead of handing
  the chat back to the user:

    * while its queue has unfinished tickets (`Burrow.Tickets`) it takes the
      next one, unless #{@max_stalls} turns in a row left the queue as it was
    * then, while the chat has a goal ("/goal <condition>"), a judge reads
      the session and says whether it holds (`judge_prompt/1`, `verdict/1`);
      if not, the agent goes on with what is missing, for at most
      #{@max_goal_turns} turns

  A turn that failed or was stopped ends it. `Burrow.Chat` keeps the run's
  counters (`new_run/0`) from the user's message on and sends what this
  says as synthetic input to the session.
  """

  alias Burrow.Tickets

  @doc "The counters of a run of turns, from the user's message on."
  def new_run, do: %{goal_turns: 0, stalls: 0, queue: nil}

  @doc """
  After a turn: `{:continue, text, run}` to go on with the queue, `:judge`
  to ask whether the goal holds, `{:stop, note}` to hand back with a note
  (the goal is over), or `:done`.
  """
  def after_turn(outcome, tickets, goal, run)

  def after_turn(outcome, _tickets, _goal, _run) when outcome != :ok, do: :done

  def after_turn(:ok, tickets, goal, run) do
    unfinished = Tickets.unfinished(tickets)
    queue = Tickets.fingerprint(tickets)
    stalls = if queue == run.queue, do: run.stalls + 1, else: 0

    cond do
      unfinished != [] and stalls >= @max_stalls ->
        {:stop,
         "The queue didn't move in #{@max_stalls} turns, so Peon stopped. " <>
           "#{count(unfinished)} left."}

      unfinished != [] ->
        {:continue, queue_text(unfinished), %{run | queue: queue, stalls: stalls}}

      goal == nil ->
        :done

      run.goal_turns >= @max_goal_turns ->
        {:stop, "Peon stopped after #{@max_goal_turns} turns without meeting the goal."}

      true ->
        :judge
    end
  end

  @doc "After the judge's verdict: `{:continue, text, run}`, or `{:met, note}` (the goal is over)."
  def after_verdict({:met, why}, _goal, _run), do: {:met, "Goal met: #{why}"}

  def after_verdict({:not_met, why}, goal, run),
    do:
      {:continue, "The goal isn't met yet: #{why}\n\nKeep working toward it: #{goal}",
       %{run | goal_turns: run.goal_turns + 1}}

  @doc "The first message of a goal, which the chat shows as `/goal <condition>`."
  def goal_text(goal) do
    """
    Your goal for this chat: #{goal}

    Work until it holds. If it takes several steps, put them in your tk queue first. \
    After each of your turns a judge reads this session to check the goal, so make \
    the evidence visible: run the tests or checks that show it.\
    """
  end

  @doc "What the judge is asked, with the whole session as its context."
  def judge_prompt(goal) do
    """
    Leave the work aside for a moment and judge it. The user set this goal:

    #{goal}

    Does it hold now? Judge only by what this session shows: tool output, test runs, \
    files written. Plans, and claims without evidence, don't count.

    Answer with one line and nothing else, either
    MET: <the evidence, in a few words>
    or
    NOT MET: <what is still missing, in a few words>\
    """
  end

  @doc "The judge's answer: `{:met, why}` or `{:not_met, why}`; its last verdict line counts."
  def verdict(text) do
    case Regex.scan(~r/^[\W_]*(NOT\s+MET|MET)\b[\W_]*(.*)$/im, text) do
      [] ->
        {:not_met, text |> String.trim() |> String.slice(0, 200)}

      lines ->
        [_, word, why] = List.last(lines)
        why = why |> String.trim() |> String.trim_trailing("*") |> String.trim()
        if word =~ ~r/^not/i, do: {:not_met, why}, else: {:met, why}
    end
  end

  defp queue_text(unfinished) do
    lines = Enum.map_join(unfinished, "\n", &"- #{&1.id} [#{&1.status}] #{&1.title}")

    """
    Your queue still has #{count(unfinished)}:
    #{lines}

    Take the next one, the first `tk ready` lists: `tk start <id>`, do it, then `tk close <id>`. \
    Go on until `tk ready` lists nothing.\
    """
  end

  defp count([_]), do: "1 unfinished ticket"
  defp count(tickets), do: "#{length(tickets)} unfinished tickets"
end
