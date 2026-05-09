defmodule BurpeeTrainer.PlanWizard.Constraints.ValidPlacement do
  @moduledoc """
  Hard constraint: every reservation lands on a real slot index in
  `1..total_reps - 1`, with no two reservations sharing a slot, and the
  reservation slot list is monotonically increasing (matches the legacy
  `prev_split + 1` invariant for `:even`).

  This is structural integrity — the actual ±30s tolerance check happens
  inside `Reservation.place/1` while the slot is being chosen. By the time
  this constraint runs, placement has succeeded; we only verify the result
  is structurally well-formed.
  """

  alias BurpeeTrainer.PlanWizard.SlotModel

  @spec check(SlotModel.t()) :: :ok | {:error, [String.t()]}
  def check(%SlotModel{reservations: []}), do: :ok

  def check(%SlotModel{} = m) do
    slot_count = length(m.weights)
    slots = Enum.map(m.reservations, & &1.slot)

    cond do
      Enum.any?(slots, &(&1 < 1 or &1 > slot_count)) ->
        {:error, ["reservation slot out of bounds (must be 1..#{slot_count})"]}

      length(Enum.uniq(slots)) != length(slots) ->
        {:error, ["multiple reservations claim the same slot"]}

      slots != Enum.sort(slots) ->
        {:error, ["reservations not in slot order"]}

      true ->
        :ok
    end
  end
end
