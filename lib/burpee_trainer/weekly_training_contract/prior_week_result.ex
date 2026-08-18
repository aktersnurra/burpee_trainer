defmodule BurpeeTrainer.WeeklyTrainingContract.PriorWeekResult do
  @moduledoc "Deterministic prior-week summary derived from authoritative completed sessions."

  @type evidence_ref :: %{required(:kind) => :session, required(:id) => pos_integer()}

  @type t :: %__MODULE__{
          week_start: Date.t(),
          completed_sec: non_neg_integer(),
          complete?: boolean(),
          workout_count: non_neg_integer(),
          evidence_refs: [evidence_ref()]
        }

  defstruct week_start: nil,
            completed_sec: 0,
            complete?: false,
            workout_count: 0,
            evidence_refs: []
end
