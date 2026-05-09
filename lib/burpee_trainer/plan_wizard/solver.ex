defmodule BurpeeTrainer.PlanWizard.Solver do
  @moduledoc """
  Orchestrates the constraint-solver pipeline:

    1. `PaceFloor.check_input/1` — pace ≥ floor for the burpee type, work
       fits in target, additional rests don't force the cadence below the
       floor.
    2. `SlotModel.new/2` — build the universal slot representation.
    3. `Reservation.place/1` — assign each `additional_rest` to a slot
       (greedy nearest, ±30s tolerance).
    4. `distribute_remaining_budget/1` — closed-form continuous solver:
       `slot_rests[i] = remaining × weight[i] / Σ(weights of non-reserved
       weighted slots)` for non-reserved slots; the reservation amount for
       reserved slots; 0 elsewhere.
    5. Hard constraints: `RestNonNegative`, `TotalDuration`,
       `ValidPlacement`.

  Returns `{:ok, %SlotModel{}}` (with `slot_rests` filled) on success, or
  `{:error, [message]}`. The `Apply` step (Session 4) takes the solved
  model and produces a `%WorkoutPlan{}`.

  Soft penalties from `MinimizePlacementError` and `MinimizeRestDeviation`
  are not currently used to pick between alternatives — the closed-form
  distribution has no alternatives to pick between. They're available for
  future re-ranking work.
  """

  alias BurpeeTrainer.PlanWizard.{PlanInput, Reservation, SlotModel}

  alias BurpeeTrainer.PlanWizard.Constraints.{
    PaceFloor,
    RestNonNegative,
    TotalDuration,
    ValidPlacement
  }

  @spec solve(PlanInput.t(), pos_integer | nil) ::
          {:ok, SlotModel.t()} | {:error, [String.t()]}
  def solve(%PlanInput{} = input, reps_per_set \\ nil) do
    with :ok <- PaceFloor.check_input(input),
         {:ok, model} <- build_slot_model(input, reps_per_set),
         {:ok, model} <- Reservation.place(model),
         {:ok, model} <- distribute_remaining_budget(model),
         :ok <- RestNonNegative.check(model),
         :ok <- TotalDuration.check(model),
         :ok <- ValidPlacement.check(model) do
      {:ok, model}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps
  # ---------------------------------------------------------------------------

  defp build_slot_model(input, reps_per_set) do
    {:ok, SlotModel.new(input, reps_per_set)}
  end

  # Distribute the remaining (non-reserved) rest budget across slots
  # proportional to their weights, skipping reserved slots and zero-weight
  # slots. Reserved slots receive their reservation rest_sec verbatim.
  defp distribute_remaining_budget(%SlotModel{} = model) do
    reserved =
      Map.new(model.reservations, fn r -> {r.slot, r.rest_sec * 1.0} end)

    budget = SlotModel.rest_budget(model)
    reserved_sum = Enum.reduce(reserved, 0.0, fn {_, v}, acc -> acc + v end)
    remaining = budget - reserved_sum

    free_weight_sum =
      model.weights
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {w, i}, acc ->
        if Map.has_key?(reserved, i), do: acc, else: acc + w
      end)

    slot_rests =
      model.weights
      |> Enum.with_index(1)
      |> Enum.map(fn {w, i} ->
        cond do
          Map.has_key?(reserved, i) -> Map.fetch!(reserved, i)
          w == 0.0 or free_weight_sum == 0.0 -> 0.0
          true -> remaining * w / free_weight_sum
        end
      end)

    {:ok, %{model | slot_rests: slot_rests}}
  end
end
