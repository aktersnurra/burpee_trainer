defmodule BurpeeTrainer.PlanSolver.Solution do
  @moduledoc """
  Output of `BurpeeTrainer.PlanSolver.solve/1`.
  """

  alias BurpeeTrainer.Workouts.WorkoutPlan

  @enforce_keys [:sec_per_burpee, :set_size, :set_count, :rest_sec, :duration_sec, :plan]
  defstruct [:sec_per_burpee, :set_size, :set_count, :rest_sec, :duration_sec, :plan]

  @type t :: %__MODULE__{
          sec_per_burpee: float,
          set_size: pos_integer,
          set_count: pos_integer,
          rest_sec: float,
          duration_sec: float,
          plan: WorkoutPlan.t()
        }
end
