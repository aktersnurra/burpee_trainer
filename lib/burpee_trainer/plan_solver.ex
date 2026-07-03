defmodule BurpeeTrainer.PlanSolver do
  @moduledoc """
  Public entry point for session plan generation.

  Plan Solver v3 normalizes input, solves the selected pacing style, then
  validates canonical execution before returning a clean `%PlanSolver.Solution{}`.
  Call `generate_plan/1` when a caller needs the derived `%WorkoutPlan{}`
  projection for editor/storage compatibility.
  """

  alias BurpeeTrainer.{Levels, PaceModel}

  alias BurpeeTrainer.PlanSolver.{
    Apply,
    EvenSolver,
    Execution,
    GeneratedPlan,
    Infeasible,
    Input,
    PacePolicy,
    Solution,
    UnbrokenSolver,
    Validator
  }

  @default_reps_per_set %{six_count: 10, navy_seal: 5}

  @doc "Type- and level-derived fastest recommended pace (sec/rep)."
  @spec sustainable_ceiling(atom, atom) :: float
  def sustainable_ceiling(burpee_type, level),
    do: PaceModel.fastest_recommended_sec_per_rep(burpee_type, level)

  @doc "Default reps-per-set for a given burpee type."
  @spec default_reps_per_set(atom) :: pos_integer
  def default_reps_per_set(type), do: Map.get(@default_reps_per_set, type, 10)

  @doc "Fastest effective pace for an input after user override and level bounds."
  @spec effective_ceiling(Input.t()) :: float
  def effective_ceiling(%Input{sec_per_rep_override: override}) when is_float(override),
    do: override

  def effective_ceiling(%Input{} = input) do
    user_ceiling = PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, input.level)
    workout_level = Levels.level_for_count(input.burpee_type, input.burpee_count_target)
    workout_ceiling = PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, workout_level)
    min(user_ceiling, workout_ceiling)
  end

  @doc "Solve a `%PlanSolver.Input{}` into canonical prescription and execution."
  @spec solve(Input.t()) :: {:ok, Solution.t()} | {:error, [String.t()]}
  def solve(%Input{} = raw_input) do
    with {:ok, {_input, solution}} <- solve_core(raw_input) do
      {:ok, solution}
    end
  end

  @doc "Generate the derived `%WorkoutPlan{}` projection from a solved input."
  @spec generate_plan(Input.t()) :: {:ok, GeneratedPlan.t()} | {:error, [String.t()]}
  def generate_plan(%Input{} = raw_input) do
    with {:ok, {input, solution}} <- solve_core(raw_input),
         {:ok, plan} <- Apply.from_execution(input, solution.execution, solution.prescription),
         :ok <- Validator.validate_persisted_plan(input, solution.execution, plan) do
      {:ok, GeneratedPlan.from(solution, plan)}
    end
  end

  defp solve_core(%Input{} = raw_input) do
    with :ok <- validate_block_pattern(raw_input),
         {:ok, input} <- Input.normalize_and_validate(raw_input),
         policy = PacePolicy.for(input.burpee_type),
         :ok <- validate_pace_override(input, policy),
         {:ok, prescription} <- solve_style(input, policy),
         execution = Execution.build(prescription),
         prescription = %{prescription | execution: execution},
         :ok <- Validator.validate_execution(input, prescription, execution) do
      {:ok, {input, Solution.from(prescription, execution)}}
    else
      {:error, %Infeasible{} = error} -> {:error, infeasible_messages(error)}
      {:error, messages} when is_list(messages) -> {:error, messages}
    end
  end

  defp solve_style(%Input{pacing_style: :even} = input, policy),
    do: EvenSolver.solve(input, policy)

  defp solve_style(%Input{pacing_style: :unbroken} = input, policy),
    do: UnbrokenSolver.solve(input, policy)

  defp validate_block_pattern(%Input{block_pattern: nil}), do: :ok

  defp validate_block_pattern(%Input{block_pattern: pattern})
       when is_list(pattern) and pattern != [] do
    if Enum.all?(pattern, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, ["block pattern must contain positive rep counts"]}
    end
  end

  defp validate_block_pattern(%Input{block_pattern: _pattern}),
    do: {:error, ["block pattern must contain 1 to 12 positive rep counts"]}

  defp validate_pace_override(%Input{sec_per_rep_override: override}, _policy)
       when is_nil(override),
       do: :ok

  defp validate_pace_override(%Input{sec_per_rep_override: override}, policy) do
    if override >= policy.hard_fastest_sec_per_rep and override <= policy.hard_slowest_sec_per_rep do
      :ok
    else
      {:error,
       %Infeasible{
         reason: :no_pace_within_hard_bounds,
         details: %{
           sec_per_rep_override: override,
           hard_fastest_sec_per_rep: policy.hard_fastest_sec_per_rep,
           hard_slowest_sec_per_rep: policy.hard_slowest_sec_per_rep
         },
         suggestions: ["Choose a pace inside the hard bounds", "Use Auto pace"]
       }}
    end
  end

  defp infeasible_messages(%Infeasible{
         reason: reason,
         suggestions: suggestions,
         details: details
       }) do
    base =
      case reason do
        :invalid_input ->
          "Invalid solver input: #{inspect(details)}."

        :advanced_structure_rep_mismatch ->
          "Manual block structure does not match target reps."

        :set_exceeds_max_unbroken ->
          "Manual block structure exceeds the max unbroken set size."

        :work_alone_exceeds_duration ->
          "Work alone does not fit in the target duration."

        :no_pace_within_hard_bounds ->
          "Target cannot be solved within hard pace bounds."

        :cannot_place_explicit_rest ->
          "Explicit rest cannot be placed on a valid boundary."

        :no_human_shaped_recovery_allocation ->
          "No human-shaped recovery allocation fits this target."
      end

    case suggestions do
      [] -> [base]
      _ -> [base <> " " <> Enum.join(suggestions, "; ") <> "."]
    end
  end
end
