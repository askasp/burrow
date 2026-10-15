defmodule Peon.VerifierTest do
  use ExUnit.Case, async: true

  import Peon.Verifier, only: [plan: 1]

  test "tests the tip first, so landings batch" do
    assert plan([{1, "passed", false}, {2, nil, false}, {3, nil, false}]) == {:test, 3}
    assert plan([{1, "passed", false}]) == :idle
    assert plan([]) == :idle
  end

  test "bisects between the last pass and the first failure" do
    chain = [
      {1, "passed", false},
      {2, nil, false},
      {3, nil, false},
      {4, nil, false},
      {5, "failed", false}
    ]

    assert plan(chain) == {:test, 3}

    chain = List.replace_at(chain, 2, {3, "passed", false})
    assert plan(chain) == {:test, 4}

    chain = List.replace_at(chain, 3, {4, "failed", false})
    assert plan(chain) == {:blame, 4}

    chain = List.replace_at(chain, 3, {4, "failed", true})
    assert plan(chain) == :idle
  end

  test "a failing tip right after a pass is the culprit" do
    assert plan([{1, "passed", false}, {2, "failed", false}]) == {:blame, 2}
  end
end
