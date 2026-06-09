defmodule BurpeeTrainer.Planning.Feedback.Repair do
  @moduledoc "One-tap repair suggestion."

  @enforce_keys [:id, :label, :action]
  defstruct [:id, :label, :action]

  @type action ::
          {:add_rest, %{target_sec: pos_integer(), duration_sec: pos_integer()}}
          | {:reduce_target_reps, pos_integer()}
          | {:use_unit_sec, pos_integer()}
          | {:lower_max_reps_per_set, pos_integer()}
          | {:try_pattern, [pos_integer()]}
          | {:remove_lock, String.t()}

  @type t :: %__MODULE__{id: String.t(), label: String.t(), action: action()}
end
