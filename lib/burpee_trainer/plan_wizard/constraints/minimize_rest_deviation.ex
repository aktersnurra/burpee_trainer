defmodule BurpeeTrainer.PlanWizard.Constraints.MinimizeRestDeviation do
  @moduledoc """
  Soft constraint: variance of slot rests across the *non-reserved,
  non-zero-weight* slots. The closed-form distribution already gives every
  such slot the same rest, so this is 0.0 in steady state — but if a future
  solver introduces variation we want a metric to score it.

      penalty = variance({slot_rests[i] | i not reserved, weight[i] > 0})
  """

  alias BurpeeTrainer.PlanWizard.SlotModel

  @spec penalty(SlotModel.t()) :: float
  def penalty(%SlotModel{slot_rests: nil}), do: 0.0

  def penalty(%SlotModel{} = m) do
    reserved = MapSet.new(m.reservations, & &1.slot)

    candidates =
      m.weights
      |> Enum.zip(m.slot_rests)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{w, r}, i} ->
        if w > 0.0 and not MapSet.member?(reserved, i), do: [r], else: []
      end)

    case candidates do
      [] ->
        0.0

      [_] ->
        0.0

      values ->
        n = length(values)
        mean = Enum.sum(values) / n
        Enum.reduce(values, 0.0, fn v, acc -> acc + :math.pow(v - mean, 2) end) / n
    end
  end
end
