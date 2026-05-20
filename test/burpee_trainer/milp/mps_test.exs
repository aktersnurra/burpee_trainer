defmodule BurpeeTrainer.Milp.MpsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Milp.{Mps, Problem}

  test "serializes a minimal problem to valid MPS" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"x", 1.0}],
      variables: [%{name: "x", type: :continuous, lower: 0.0, upper: :pos_inf}],
      constraints: [
        %{name: "C1", terms: [{"x", 1.0}], comparator: :leq, rhs: 10.0}
      ]
    }

    text = Mps.serialize(problem)

    assert text =~ ~r/^NAME\s+BURPEE_PLAN/
    assert text =~ "ROWS"
    assert text =~ "COLUMNS"
    assert text =~ "RHS"
    assert text =~ "BOUNDS"
    assert text =~ ~r/ENDATA\s*\z/
    assert text =~ ~r/^\s*N\s+COST/m
    assert text =~ ~r/^\s*L\s+C1/m
  end

  test "wraps binary variables in INTORG/INTEND markers" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [],
      variables: [
        %{name: "x", type: :binary, lower: 0.0, upper: 1.0}
      ],
      constraints: []
    }

    text = Mps.serialize(problem)
    assert text =~ "'INTORG'"
    assert text =~ "'INTEND'"
  end

  test "emits LO bound for variable with non-zero lower" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"p", -1.0}],
      variables: [%{name: "p", type: :continuous, lower: 5.0, upper: :pos_inf}],
      constraints: []
    }

    text = Mps.serialize(problem)
    assert text =~ ~r/LO BND\s+p\s+5\.000000/
  end
end
