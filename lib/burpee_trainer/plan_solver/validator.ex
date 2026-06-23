defmodule BurpeeTrainer.PlanSolver.Validator do
  @moduledoc "Validates Plan Solver v3 canonical and persisted invariants."

  alias BurpeeTrainer.PlanSolver.{Execution, Infeasible, Input, Prescription}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @epsilon 1.0e-6
  @persisted_duration_tolerance_sec 1.0

  @spec validate_execution(Input.t(), Prescription.t(), Execution.t()) ::
          :ok | {:error, Infeasible.t()}
  def validate_execution(%Input{} = input, %Prescription{} = prescription, execution) do
    cond do
      Execution.burpee_count(execution) != input.burpee_count_target ->
        invalid(:invalid_input, %{
          invariant: :target_reps,
          execution_reps: Execution.burpee_count(execution),
          target_reps: input.burpee_count_target
        })

      abs(Execution.duration_sec(execution) - input.target_duration_sec) > @epsilon ->
        invalid(:invalid_input, %{
          invariant: :target_duration,
          execution_duration_sec: Execution.duration_sec(execution),
          target_duration_sec: input.target_duration_sec
        })

      prescription.pacing_style != input.pacing_style ->
        invalid(:invalid_input, %{invariant: :pacing_style})

      true ->
        :ok
    end
  end

  @spec validate_persisted_plan(Input.t(), Execution.t(), WorkoutPlan.t()) ::
          :ok | {:error, Infeasible.t()}
  def validate_persisted_plan(%Input{} = input, execution, %WorkoutPlan{} = plan) do
    summary = BurpeeTrainer.Planner.summary(plan)
    execution_duration = Execution.duration_sec(execution)
    execution_count = Execution.burpee_count(execution)

    cond do
      summary.burpee_count_total != execution_count ->
        invalid(:invalid_input, %{
          invariant: :persisted_reps_match_execution,
          persisted_reps: summary.burpee_count_total,
          execution_reps: execution_count
        })

      abs(summary.duration_sec_total - execution_duration) > @persisted_duration_tolerance_sec ->
        invalid(:invalid_input, %{
          invariant: :persisted_duration_match_execution,
          persisted_duration_sec: summary.duration_sec_total,
          execution_duration_sec: execution_duration
        })

      summary.burpee_count_total != input.burpee_count_target ->
        invalid(:invalid_input, %{
          invariant: :persisted_reps_match_target,
          persisted_reps: summary.burpee_count_total,
          target_reps: input.burpee_count_target
        })

      abs(summary.duration_sec_total - input.target_duration_sec) >
          @persisted_duration_tolerance_sec ->
        invalid(:invalid_input, %{
          invariant: :persisted_duration_match_target,
          persisted_duration_sec: summary.duration_sec_total,
          target_duration_sec: input.target_duration_sec
        })

      true ->
        :ok
    end
  end

  defp invalid(reason, details) do
    {:error, %Infeasible{reason: reason, details: details, suggestions: []}}
  end
end
