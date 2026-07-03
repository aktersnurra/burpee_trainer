defmodule BurpeeTrainer.PlanSolver.GeneratedPlan do
  @moduledoc """
  Explicit adapter result for callers that need a generated `%WorkoutPlan{}`.

  The solver core returns `PlanSolver.Solution`; this projection keeps the
  editor/storage compatibility shape outside `PlanSolver.solve/1`.
  """

  alias BurpeeTrainer.PlanSolver.{Execution, Solution}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @enforce_keys [
    :solution,
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
    :prescription,
    :plan
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          solution: Solution.t(),
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
          metadata: map,
          execution: Execution.t(),
          prescription: BurpeeTrainer.PlanSolver.Prescription.t(),
          plan: WorkoutPlan.t()
        }

  @spec from(Solution.t(), WorkoutPlan.t()) :: t()
  def from(%Solution{} = solution, %WorkoutPlan{} = plan) do
    prescription = solution.prescription

    rest_pattern_sec =
      solution.execution
      |> Enum.filter(&match?(%Execution.RestEvent{}, &1))
      |> Enum.map(& &1.rest_sec)

    %__MODULE__{
      solution: solution,
      sec_per_burpee: prescription.sec_per_rep,
      set_size: Enum.max(prescription.set_pattern),
      set_count: length(prescription.set_pattern),
      rest_sec: average_rest(rest_pattern_sec),
      duration_sec: prescription.target_duration_sec,
      set_pattern: prescription.set_pattern,
      rest_pattern_sec: rest_pattern_sec,
      burpee_count: prescription.burpee_count,
      pacing_style: prescription.pacing_style,
      burpee_type: prescription.burpee_type,
      metadata: prescription.metadata,
      execution: solution.execution,
      prescription: prescription,
      plan: plan
    }
  end

  defp average_rest([]), do: 0.0
  defp average_rest(rest_pattern_sec), do: Enum.sum(rest_pattern_sec) / length(rest_pattern_sec)
end
