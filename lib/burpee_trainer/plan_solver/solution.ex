defmodule BurpeeTrainer.PlanSolver.Solution do
  @moduledoc """
  Output of `BurpeeTrainer.PlanSolver.solve/1`.

  `execution` is the canonical solved prescription. The persisted `plan` is a
  derived representation for storage/editing and is validated against execution
  before a solution is returned.
  """

  alias BurpeeTrainer.Workouts.WorkoutPlan

  @enforce_keys [
    :sec_per_burpee,
    :set_size,
    :set_count,
    :rest_sec,
    :duration_sec,
    :set_pattern,
    :rest_pattern_sec,
    :burpee_count,
    :pacing_style,
    :burpee_type,
    :metadata,
    :execution,
    :plan
  ]
  defstruct [
    :sec_per_burpee,
    :set_size,
    :set_count,
    :rest_sec,
    :duration_sec,
    :set_pattern,
    :rest_pattern_sec,
    :burpee_count,
    :pacing_style,
    :burpee_type,
    :metadata,
    :execution,
    :plan
  ]

  @type metadata :: %{
          solver_version: String.t(),
          set_pattern_strategy: atom,
          candidate_count: non_neg_integer,
          score: float,
          pace_fastest_sec_per_rep: float,
          pace_slowest_sec_per_rep: float,
          pace_override?: boolean
        }

  @type t :: %__MODULE__{
          sec_per_burpee: float,
          set_size: pos_integer,
          set_count: pos_integer,
          rest_sec: float,
          duration_sec: float,
          set_pattern: [pos_integer],
          rest_pattern_sec: [float],
          burpee_count: pos_integer,
          pacing_style: atom,
          burpee_type: atom,
          metadata: metadata,
          execution: BurpeeTrainer.PlanSolver.Execution.t(),
          plan: WorkoutPlan.t()
        }
end
