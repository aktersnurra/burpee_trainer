defmodule BurpeeTrainer.PlanWizard.Constraints.RestNonNegative do
  @moduledoc """
  Hard constraint: `slot_rests[i] >= 0` for every slot.

  Equivalent in math to PaceFloor.check_distributed/1, but framed in terms
  of slot variables rather than user-facing pace. Used by the solver after
  the continuous distribution step.
  """

  alias BurpeeTrainer.PlanWizard.SlotModel

  @epsilon 1.0e-9

  @spec check(SlotModel.t()) :: :ok | {:error, [String.t()]}
  def check(%SlotModel{slot_rests: nil}), do: :ok

  def check(%SlotModel{slot_rests: rests}) do
    case Enum.find_index(rests, &(&1 < -@epsilon)) do
      nil -> :ok
      idx -> {:error, ["slot #{idx + 1} has negative rest (#{Enum.at(rests, idx)})"]}
    end
  end
end
