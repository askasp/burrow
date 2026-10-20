defmodule Peon.Env.Usage do
  @moduledoc """
  An environment's usage over the last two hours, a point a minute, from the
  attacher's stats (`"usage"`: requests and their p95 since the last stats,
  LiveView sessions now, visitors today) and the errors it forwards.
  """

  @minutes 120

  defstruct minute: nil, requests: 0, p95: nil, sessions: 0, visitors: 0, history: [], errors: []

  def new, do: %__MODULE__{}

  @doc "Adds one stats report, taken at `now` (unix seconds)."
  def add(%__MODULE__{} = usage, report, now) do
    minute = div(now, 60)

    usage =
      if usage.minute && usage.minute != minute,
        do: %{close(usage) | requests: 0, p95: nil},
        else: usage

    %{
      usage
      | minute: minute,
        requests: usage.requests + (report["requests"] || 0),
        p95: max_p95(usage.p95, report["p95"]),
        sessions: report["sessions"] || 0,
        visitors: report["visitors"] || 0
    }
  end

  defp close(usage) do
    point = %{sessions: usage.sessions, rpm: usage.requests, p95: usage.p95 || 0}
    %{usage | history: Enum.take(usage.history ++ [point], -@minutes)}
  end

  defp max_p95(nil, p95), do: p95
  defp max_p95(p95, nil), do: p95
  defp max_p95(a, b), do: max(a, b)

  @doc "An error the app logged at `now`."
  def error(%__MODULE__{} = usage, now),
    do: %{usage | errors: [now | Enum.filter(usage.errors, &(&1 > now - 3600))]}

  @doc """
  `%{sessions, rpm, p95, visitors, errors, history}`: now, requests in the
  last full minute, its p95, visitors today, errors in the last hour, and a
  point a minute for the sparklines.
  """
  def summary(%__MODULE__{} = usage, now) do
    last = List.last(usage.history)

    %{
      sessions: usage.sessions,
      rpm: if(last, do: last.rpm, else: usage.requests),
      p95: if(last, do: last.p95, else: usage.p95),
      visitors: usage.visitors,
      errors: Enum.count(usage.errors, &(&1 > now - 3600)),
      history: usage.history
    }
  end
end
