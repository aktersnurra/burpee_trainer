defmodule BurpeeTrainer.PlanSolver.Solution do
  @moduledoc """
  Output of `BurpeeTrainer.PlanSolver.solve/1`.

  `execution` is the canonical solved prescription. The persisted `plan` is a
  derived representation for storage/editing and is validated against execution
  before a solution is returned.
  """

  alias BurpeeTrainer.PlanSolver.{Execution, Prescription}
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
    :prescription,
    :plan
  ]

  @type metadata :: map

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
          execution: Execution.t(),
          prescription: Prescription.t() | nil,
          plan: WorkoutPlan.t()
        }

  @spec from(Prescription.t(), Execution.t(), WorkoutPlan.t()) :: t()
  def from(%Prescription{} = prescription, execution, %WorkoutPlan{} = plan) do
    rest_pattern_sec =
      execution
      |> Enum.filter(&match?(%Execution.RestEvent{}, &1))
      |> Enum.map(& &1.rest_sec)

    %__MODULE__{
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
      execution: execution,
      prescription: prescription,
      plan: plan
    }
  end

  defp average_rest([]), do: 0.0
  defp average_rest(rest_pattern_sec), do: Enum.sum(rest_pattern_sec) / length(rest_pattern_sec)
end
