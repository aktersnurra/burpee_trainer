defmodule BurpeeTrainer.PlanEditor.PlanStep do
  @moduledoc "Transient source/program step projection used by the workout editor."

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :plan_id,
    :position,
    :kind,
    :block_position,
    :repeat_count,
    :rest_sec,
    inserted_at: nil,
    updated_at: nil
  ]
end
