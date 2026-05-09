defmodule BurpeeTrainer.PlanWizard.Constraints.TotalDuration do
  @moduledoc """
  Hard constraint: the sum of work + slot rests + reservations must equal
  the target duration within ±1 second of floating-point slack.

      |work + Σ(slot_rests) + Σ(reservations) − target| ≤ 1.0
  """

  alias BurpeeTrainer.PlanWizard.SlotModel

  @tolerance_sec 1.0

  @spec check(SlotModel.t()) :: :ok | {:error, [String.t()]}
  def check(%SlotModel{slot_rests: nil}), do: :ok

  def check(%SlotModel{} = m) do
    work = SlotModel.work_sec(m)
    rest = Enum.sum(m.slot_rests)
    reserved = Enum.reduce(m.reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    actual = work + rest + reserved
    diff = abs(actual - m.target_duration_sec)

    if diff <= @tolerance_sec do
      :ok
    else
      {:error,
       [
         "total duration #{Float.round(actual, 2)}s differs from target " <>
           "#{m.target_duration_sec}s by #{Float.round(diff, 2)}s (max #{@tolerance_sec}s)"
       ]}
    end
  end
end
