defmodule BurpeeTrainer.PlanEditor.Derived do
  @moduledoc """
  Derived editor values computed from the current form and solver state.
  """

  @type summary :: %{
          duration_sec: non_neg_integer() | float(),
          burpee_count: non_neg_integer(),
          target_sec: pos_integer(),
          target_count: pos_integer(),
          duration_ok: boolean(),
          count_ok: boolean(),
          both_ok: boolean()
        }

  defstruct [:summary, :duration_ok?, :reps_ok?, :can_save?]

  @type t :: %__MODULE__{
          summary: summary() | nil,
          duration_ok?: boolean() | nil,
          reps_ok?: boolean() | nil,
          can_save?: boolean() | nil
        }
end
