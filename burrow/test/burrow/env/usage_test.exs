defmodule Burrow.Env.UsageTest do
  use ExUnit.Case, async: true

  alias Burrow.Env.Usage

  test "a point a minute: requests summed, the worst p95, sessions and visitors as last seen" do
    usage =
      Usage.new()
      |> Usage.add(%{"requests" => 3, "p95" => 40, "sessions" => 2, "visitors" => 5}, 600)
      |> Usage.add(%{"requests" => 4, "p95" => 90, "sessions" => 3, "visitors" => 6}, 610)

    # Before a minute is full, it shows the minute so far.
    assert %{rpm: 7, p95: 90, sessions: 3, visitors: 6, history: []} = Usage.summary(usage, 610)

    usage =
      Usage.add(usage, %{"requests" => 1, "p95" => nil, "sessions" => 1, "visitors" => 6}, 660)

    assert %{rpm: 7, p95: 90, sessions: 1, history: [%{rpm: 7, p95: 90, sessions: 3}]} =
             Usage.summary(usage, 660)
  end

  test "errors count for an hour" do
    usage = Usage.new() |> Usage.error(100) |> Usage.error(2000)
    assert Usage.summary(usage, 3000).errors == 2
    assert Usage.summary(usage, 3800).errors == 1
  end
end
