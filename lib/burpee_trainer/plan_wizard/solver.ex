defmodule BurpeeTrainer.PlanWizard.Solver do
  @moduledoc """
  Orchestrates the MILP solver pipeline:

    1. `PaceFloor.check_input/1` — pace ≥ floor, work fits in target,
       additional rests don't force cadence below floor.
    2. `SlotModel.new/2` — build universal slot representation.
    3. `Lp.build/1` — construct `%Lp.Problem{}` from the slot model.
    4. `Highs.solve/1` — invoke HiGHS, parse solution.
    5. Inject `r[i]` values into `slot_rests`; populate `reservations` from
       the binary assignment values for downstream `Apply`.

  Errors from HiGHS are mapped to user-facing strings via
  `BurpeeTrainer.PlanWizard.Errors`.
  """

  alias BurpeeTrainer.PlanWizard.{Errors, Highs, Lp, PlanInput, SlotModel}
  alias BurpeeTrainer.PlanWizard.Constraints.PaceFloor

  @spec solve(PlanInput.t(), pos_integer | nil) ::
          {:ok, SlotModel.t()} | {:error, [String.t()]}
  def solve(%PlanInput{} = input, reps_per_set \\ nil) do
    with :ok <- PaceFloor.check_input(input),
         model = SlotModel.new(input, reps_per_set),
         problem = Lp.build(model),
         {:ok, %{r: r}} <- run_solver(problem, input) do
      {:ok, fill_solution(model, r)}
    end
  end

  defp run_solver(problem, input) do
    case Highs.solve(problem) do
      {:ok, _} = ok ->
        ok

      {:error, :infeasible} ->
        {:error, [infeasibility_message(input)]}

      {:error, :timeout} ->
        {:error, ["plan solver timed out"]}

      {:error, {:exit, code, output}} ->
        {:error, ["plan solver failed (exit #{code}): #{output}"]}
    end
  end

  defp infeasibility_message(%PlanInput{additional_rests: [_ | _] = rests, pacing_style: style}) do
    %{target_min: t} = Enum.max_by(rests, & &1.target_min)

    case style do
      :even ->
        Errors.cannot_place_rest_out_of_tolerance_even(t, t, Errors.placement_tolerance_sec())

      :unbroken ->
        Errors.cannot_place_rest_out_of_tolerance_unbroken(t, t, Errors.placement_tolerance_sec())
    end
  end

  defp infeasibility_message(%PlanInput{} = input) do
    work_sec = input.burpee_count_target * input.sec_per_burpee
    target_sec = input.target_duration_min * 60
    Errors.work_exceeds_target(work_sec, target_sec)
  end

  defp fill_solution(%SlotModel{} = model, r) do
    reservations = recover_reservations(model, r)
    %{model | slot_rests: r, reservations: reservations}
  end

  defp recover_reservations(%SlotModel{additional_rests_input: []}, _r), do: []

  defp recover_reservations(%SlotModel{} = model, r) do
    {result, _taken} =
      model.additional_rests_input
      |> Enum.sort_by(& &1.target_min)
      |> Enum.map_reduce(MapSet.new(), fn rest, taken ->
        slot =
          r
          |> Enum.with_index(1)
          |> Enum.reject(fn {_v, i} -> MapSet.member?(taken, i) end)
          |> Enum.min_by(fn {v, _i} -> abs(v - rest.rest_sec) end)
          |> elem(1)

        reservation = %{slot: slot, rest_sec: rest.rest_sec, target_min: rest.target_min}
        {reservation, MapSet.put(taken, slot)}
      end)

    result
  end
end
