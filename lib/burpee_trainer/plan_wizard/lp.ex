defmodule BurpeeTrainer.PlanWizard.Lp do
  @moduledoc """
  Builds an `%Lp.Problem{}` from a `%SlotModel{}`. Pure function — no I/O.

  Reservations contribute binary `x_<k>_<i>` assignment variables and the
  linearization machinery (`y_<k>_<i>`, big-M rest-amount linkage,
  placement-error rows). When there are no reservations, the problem
  reduces to: find `r_i ≥ 0` summing to `rest_budget(model)`, minimize
  `Σ |r_i - r_ideal[i]|` (linearized via `e_i`).
  """

  alias BurpeeTrainer.PlanWizard.SlotModel
  alias BurpeeTrainer.PlanWizard.Lp.Problem

  @epsilon 1.0e-3

  @spec build(SlotModel.t()) :: Problem.t()
  def build(%SlotModel{} = model) do
    n = model.total_reps
    slot_count = n - 1
    ideal = SlotModel.ideal_rests(model)
    budget = SlotModel.rest_budget(model)

    r_vars = for i <- 1..slot_count, do: continuous("r_#{i}")
    e_vars = for i <- 1..slot_count, do: continuous("e_#{i}")

    constraints =
      [total_duration_row(slot_count, budget)] ++
        zero_weight_rows(model) ++
        deviation_rows(slot_count, ideal)

    objective_terms = for i <- 1..slot_count, do: {"e_#{i}", @epsilon}

    %Problem{
      objective_sense: :minimize,
      objective_terms: objective_terms,
      variables: r_vars ++ e_vars,
      constraints: constraints
    }
  end

  defp continuous(name),
    do: %{name: name, type: :continuous, lower: 0.0, upper: :pos_inf}

  defp total_duration_row(slot_count, budget) do
    %{
      name: "TOTAL_DUR",
      terms: for(i <- 1..slot_count, do: {"r_#{i}", 1.0}),
      comparator: :eq,
      rhs: budget * 1.0
    }
  end

  defp zero_weight_rows(%SlotModel{weights: weights}) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {w, i} when w == 0.0 ->
        [%{name: "ZERO_SLOT_#{i}", terms: [{"r_#{i}", 1.0}], comparator: :eq, rhs: 0.0}]

      _ ->
        []
    end)
  end

  defp deviation_rows(slot_count, ideal) do
    Enum.flat_map(1..slot_count, fn i ->
      ideal_i = Enum.at(ideal, i - 1)

      [
        %{
          name: "DEV_POS_#{i}",
          terms: [{"r_#{i}", -1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: -ideal_i
        },
        %{
          name: "DEV_NEG_#{i}",
          terms: [{"r_#{i}", 1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: ideal_i
        }
      ]
    end)
  end
end
