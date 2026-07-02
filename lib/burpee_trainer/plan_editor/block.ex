defmodule BurpeeTrainer.PlanEditor.Block do
  @moduledoc "Transient source/program projection used by the workout editor."

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :plan_id,
    :position,
    repeat_count: 1,
    sets: [],
    inserted_at: nil,
    updated_at: nil
  ]
end
