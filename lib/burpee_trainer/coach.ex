defmodule BurpeeTrainer.Coach do
  @moduledoc "Creates and refines verified user-scoped workout drafts."

  alias BurpeeTrainer.{Accounts, Workouts}
  alias BurpeeTrainer.Coach.Client
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan}

  require Logger

  @authoring_max_graphemes 500
  @authoring_max_bytes 4_000

  @authoring_system_prompt """
  Return only one JSON object matching the version 1 workout definition schema. The definition
  must contain exactly version, name, burpee_type, target_duration_sec, target_reps,
  pacing_style, rationale, and events. Include at least one work event. The sum of reps across
  every work event must equal target_reps; rest events contribute zero reps. When the user requests
  no rest, events must contain no rest events. Event durations must sum exactly to
  target_duration_sec using the formulas in the schema. Check both totals before returning JSON.
  """

  @spec create_draft(Accounts.User.t(), String.t(), keyword()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def create_draft(user, request, opts \\ [])

  def create_draft(%Accounts.User{} = user, request, opts)
      when is_binary(request) and is_list(opts) do
    with {:ok, request} <- validate_authoring_input(request) do
      started_at = System.monotonic_time()

      result =
        with {:ok, provider_definition} <-
               Client.complete(
                 [
                   %{role: "system", content: @authoring_system_prompt},
                   %{role: "user", content: request}
                 ],
                 opts
               ),
             {:ok, definition} <- validate_provider_definition(provider_definition) do
          Workouts.create_user_draft(user, %{
            definition: WorkoutDefinition.canonical_map(definition),
            request_text: request
          })
        end

      log_create_failure(result, started_at)
    end
  end

  def create_draft(%Accounts.User{}, _request, _opts),
    do: {:error, Error.new(:invalid_workout_definition)}

  @spec refine_draft(Accounts.User.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def refine_draft(user, draft_id, instruction, opts \\ [])

  def refine_draft(%Accounts.User{} = user, draft_id, instruction, opts)
      when is_integer(draft_id) and draft_id > 0 and is_binary(instruction) and is_list(opts) do
    with {:ok, draft} <- refinable_draft(user, draft_id),
         {:ok, instruction} <- validate_authoring_input(instruction),
         refinement <-
           Jason.encode!(%{
             current_definition: draft.definition_json,
             instruction: instruction
           }),
         {:ok, provider_definition} <-
           Client.complete(
             [
               %{role: "system", content: @authoring_system_prompt},
               %{role: "user", content: refinement}
             ],
             opts
           ),
         {:ok, definition} <- validate_provider_definition(provider_definition) do
      Workouts.replace_draft(user, draft.id, %{
        definition: WorkoutDefinition.canonical_map(definition),
        request_text: instruction,
        expected_revision: draft
      })
    end
  end

  def refine_draft(%Accounts.User{}, draft_id, _instruction, _opts),
    do: {:error, Error.new(:draft_not_found, %{draft_id: draft_id})}

  defp refinable_draft(%Accounts.User{} = user, draft_id) do
    case Workouts.get_draft(user, draft_id) do
      {:error, %Error{code: :draft_required}} ->
        {:error, Error.new(:workout_immutable, %{draft_id: draft_id})}

      result ->
        result
    end
  end

  defp log_create_failure({:error, %Error{} = error} = result, started_at) do
    elapsed_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :millisecond)

    provider_status =
      case error.context do
        %{status: status} when is_integer(status) -> Integer.to_string(status)
        _other -> "none"
      end

    Logger.warning(
      "workout_draft_create_failed error_code=#{error.code} " <>
        "provider_status=#{provider_status} elapsed_ms=#{elapsed_ms}"
    )

    result
  end

  defp log_create_failure(result, _started_at), do: result

  defp validate_authoring_input(input) when is_binary(input) do
    input = String.trim(input)

    if input != "" and String.length(input) <= @authoring_max_graphemes and
         byte_size(input) <= @authoring_max_bytes do
      {:ok, input}
    else
      {:error, Error.new(:invalid_workout_definition)}
    end
  end

  defp validate_provider_definition(provider_definition) do
    case WorkoutDefinition.new(provider_definition) do
      {:ok, definition} -> validate_compiled_definition(definition)
      {:error, %Error{} = error} -> reject_provider_definition(:schema, error)
    end
  end

  defp validate_compiled_definition(definition) do
    case BurpeeTrainer.PlanCompiler.compile(definition) do
      {:ok, _program} -> {:ok, definition}
      {:error, %Error{} = error} -> reject_provider_definition(:compile, error)
    end
  end

  defp reject_provider_definition(phase, %Error{} = error) do
    field = Map.get(error.context, :field, :none)
    arithmetic = safe_validation_arithmetic(error.context)

    Logger.warning(
      "workout_definition_rejected phase=#{phase} error_code=#{error.code} " <>
        "field=#{format_validation_field(field)}#{arithmetic}"
    )

    if error.code == :infeasible_workout_definition do
      {:error, Error.new(:infeasible_workout_definition)}
    else
      {:error, Error.new(:invalid_workout_definition)}
    end
  end

  defp format_validation_field(field) when is_atom(field), do: Atom.to_string(field)
  defp format_validation_field(field), do: inspect(field)

  defp safe_validation_arithmetic(%{value: %{actual: actual, expected: expected}})
       when is_number(actual) and is_number(expected),
       do: " actual=#{actual} expected=#{expected}"

  defp safe_validation_arithmetic(%{value: %{actual_us: actual, expected_us: expected}})
       when is_integer(actual) and is_integer(expected),
       do: " actual_us=#{actual} expected_us=#{expected}"

  defp safe_validation_arithmetic(_context), do: ""
end
