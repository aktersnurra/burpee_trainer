defmodule BurpeeTrainer.PlanWizard.Constraints.MinimizePlacementError do
  @moduledoc """
  Soft constraint: total absolute error between requested `target_min × 60`
  and the actual wall-clock time of each placed reservation.

      penalty = Σ |slot_time(r.slot) − r.target_min × 60|

  Lower is better. The current solver doesn't optimise across alternatives
  (greedy nearest-slot already minimises this locally), so this is computed
  for visibility/telemetry only.
  """

  alias BurpeeTrainer.PlanWizard.SlotModel

  @spec penalty(SlotModel.t()) :: float
  def penalty(%SlotModel{reservations: []}), do: 0.0

  def penalty(%SlotModel{slot_rests: nil}), do: 0.0

  def penalty(%SlotModel{} = m) do
    slot_times = cumulative_slot_times(m)

    Enum.reduce(m.reservations, 0.0, fn r, acc ->
      actual = Enum.at(slot_times, r.slot - 1) || 0.0
      acc + abs(actual - r.target_min * 60.0)
    end)
  end

  defp cumulative_slot_times(%SlotModel{} = m) do
    {times, _} =
      m.slot_rests
      |> Enum.with_index(1)
      |> Enum.map_reduce(0.0, fn {rest, i}, acc ->
        t = i * m.sec_per_burpee + acc + rest
        {t, acc + rest}
      end)

    times
  end
end
