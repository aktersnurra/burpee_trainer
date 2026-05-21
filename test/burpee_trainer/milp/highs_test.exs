defmodule BurpeeTrainer.Milp.HighsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Milp.{Highs, Problem}

  @moduletag :highs

  test "solves a trivial LP and returns r: [], p: nil" do
    # minimize -x subject to x <= 10, x >= 0
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"x", -1.0}],
      variables: [%{name: "x", type: :continuous, lower: 0.0, upper: :pos_inf}],
      constraints: [
        %{name: "C1", terms: [{"x", 1.0}], comparator: :leq, rhs: 10.0}
      ]
    }

    assert {:ok, %{r: [], p: nil, objective: obj}} = Highs.solve(problem)
    assert_in_delta obj, -10.0, 1.0e-3
  end

  test "extracts named variable p from solution" do
    # minimize -p subject to p <= 10, p >= 5
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"p", -1.0}],
      variables: [%{name: "p", type: :continuous, lower: 5.0, upper: 10.0}],
      constraints: [
        %{name: "C1", terms: [{"p", 1.0}], comparator: :leq, rhs: 10.0}
      ]
    }

    assert {:ok, %{r: [], p: p, objective: obj}} = Highs.solve(problem)
    assert is_float(p)
    assert p >= 5.0 - 1.0e-6
    assert_in_delta obj, -10.0, 1.0e-3
  end

  test "returns :infeasible for contradictory constraints" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"x", 1.0}],
      variables: [%{name: "x", type: :continuous, lower: 0.0, upper: :pos_inf}],
      constraints: [
        %{name: "C1", terms: [{"x", 1.0}], comparator: :leq, rhs: -1.0}
      ]
    }

    assert {:error, :infeasible} = Highs.solve(problem)
  end
end
