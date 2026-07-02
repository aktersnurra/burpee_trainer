defmodule BurpeeTrainer.PlanEditor.Set do
  @moduledoc "Transient source/program set projection used by the workout editor."

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :block_id,
    :position,
    :burpee_count,
    :sec_per_rep,
    sec_per_burpee: 3.0,
    end_of_set_rest: 0,
    duration_min: nil,
    inserted_at: nil,
    updated_at: nil
  ]
end
