defmodule BurpeeTrainer.Coach do
  @moduledoc "Creates and refines verified user-scoped workout drafts."

  alias BurpeeTrainer.{Accounts, Workouts}
  alias BurpeeTrainer.Coach.{Client, Context}
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

  def revise_home_workout(user, expected, instruction, opts \\ []) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, source} <- Workouts.verify_home_selection(user, expected),
         {:ok, context} <- Context.ensure_session(user, source, Context.home_key(expected)) do
      author_attempt(user, source, context, text, opts, fn definition, attempt ->
        Workouts.commit_home_revision(user, expected, definition, text, context.id, attempt)
      end)
    end
  end

  @spec create_draft(Accounts.User.t(), String.t(), keyword()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def create_draft(user, request, opts \\ [])

  def create_draft(%Accounts.User{} = user, request, opts)
      when is_binary(request) and is_list(opts) do
    started_at = System.monotonic_time()

    result =
      with :ok <- outside_authoring_transaction(),
           {:ok, text} <- validate_authoring_input(request),
           key <- Keyword.get(opts, :workspace_key, "creator:#{Ecto.UUID.generate()}"),
           {:ok, context} <- Context.ensure_session(user, nil, key) do
        author_attempt(user, nil, context, text, opts, fn definition, attempt ->
          Workouts.commit_authored_revision(user, nil, definition, text, context.id, attempt)
        end)
      end

    log_create_failure(result, started_at)
  end

  def create_draft(%Accounts.User{}, _request, _opts),
    do: {:error, Error.new(:invalid_workout_definition)}

  @spec refine_draft(Accounts.User.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def refine_draft(user, id, instruction, opts \\ [])

  def refine_draft(%Accounts.User{} = user, id, instruction, opts)
      when is_integer(id) and id > 0 and is_binary(instruction) and is_list(opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, draft} <- refinable_draft(user, id),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, context} <- Context.ensure_session(user, draft, "draft:#{draft.id}") do
      author_attempt(user, draft, context, text, opts, fn definition, attempt ->
        Workouts.commit_authored_revision(user, draft, definition, text, context.id, attempt)
      end)
    end
  end

  def refine_draft(%Accounts.User{}, id, _instruction, _opts),
    do: {:error, Error.new(:draft_not_found, %{draft_id: id})}

  defp author_attempt(user, source, context, text, opts, commit) do
    attempt = Ecto.UUID.generate()

    with {:ok, _} <- Context.append(user, context.id, attempt, :instruction, %{"text" => text}) do
      result =
        safe_authoring(fn ->
          with {:ok, messages} <-
                 Context.messages(user, context.id, source, attempt, @authoring_system_prompt),
               {:ok, proposal} <-
                 Client.complete(
                   messages,
                   Keyword.put(opts, :response_kind, :workout_definition)
                 ),
               {:ok, _} <-
                 Context.append(user, context.id, attempt, :proposal, %{"definition" => proposal}),
               {:ok, definition} <- validate_provider_definition(proposal) do
            commit.(WorkoutDefinition.canonical_map(definition), attempt)
          end
        end)

      record_failed_outcome(user, context.id, attempt, result)
    end
  end

  defp outside_authoring_transaction do
    if BurpeeTrainer.Repo.in_transaction?(),
      do: {:error, Error.new(:authoring_transaction_forbidden)},
      else: :ok
  end

  defp safe_authoring(fun) do
    fun.()
  rescue
    _ -> {:error, Error.new(:provider_unavailable)}
  catch
    :exit, _ -> {:error, Error.new(:provider_unavailable)}
    :throw, _ -> {:error, Error.new(:provider_unavailable)}
  end

  defp record_failed_outcome(user, id, attempt, {:error, %Error{} = error} = original) do
    recorded =
      try do
        Context.append(user, id, attempt, :outcome, %{
          "status" => "failed",
          "code" => Atom.to_string(error.code)
        })
      rescue
        _ -> {:error, :log_unavailable}
      catch
        _, _ -> {:error, :log_unavailable}
      end

    if not match?({:ok, _}, recorded),
      do: Logger.warning("workout_design_failure_outcome_unavailable")

    original
  end

  defp record_failed_outcome(_user, _id, _attempt, result), do: result

  def recommend_workout(user, recommendation, original_messages, opts) do
    key = "recommendation:#{recommendation.id}:#{recommendation.selected_workout_plan_id}"

    with :ok <- outside_authoring_transaction(),
         {:ok, context} <- Context.ensure_session(user, nil, key) do
      attempt = Ecto.UUID.generate()

      with {:ok, _} <-
             Context.append(user, context.id, attempt, :instruction, %{
               "text" => "Choose the next workout for this slot.",
               "request_messages" => original_messages
             }) do
        result =
          safe_authoring(fn ->
            with {:ok, messages} <-
                   Context.messages(
                     user,
                     context.id,
                     nil,
                     attempt,
                     "Return the coach recommendation schema; use the active attempt's slot and library facts."
                   ),
                 {:ok, response} <-
                   Client.complete(
                     messages,
                     Keyword.put(opts, :response_kind, :coach_recommendation)
                   ),
                 {:ok, _} <- Context.append(user, context.id, attempt, :proposal, response) do
              BurpeeTrainer.Repo.immediate_transaction(fn ->
                expected = {:plan, recommendation.selected_workout_plan_id}

                with {:ok, changed} <-
                       BurpeeTrainer.Coach.Recommendation.apply_proposal(
                         user,
                         recommendation.id,
                         response,
                         expected
                       ),
                     :ok <- link_recommendation_context(user, changed, context.id),
                     {:ok, _} <-
                       Context.append(user, context.id, attempt, :outcome, %{
                         "status" => "accepted",
                         "pending_draft_id" => changed.pending_draft_id,
                         "selected_plan_id" => changed.selected_workout_plan_id
                       }) do
                  changed
                else
                  {:error, error} -> BurpeeTrainer.Repo.rollback(error)
                end
              end)
            end
          end)

        record_failed_outcome(user, context.id, attempt, result)
      end
    end
  end

  defp link_recommendation_context(_user, %{pending_draft_id: nil}, _id), do: :ok

  defp link_recommendation_context(user, recommendation, id) do
    with {:ok, draft} <- Workouts.get_draft(user, recommendation.pending_draft_id),
         :ok <- Context.check_source(user, id, nil) do
      case draft |> Ecto.Changeset.change(design_session_id: id) |> BurpeeTrainer.Repo.update() do
        {:ok, _} -> :ok
        {:error, _} -> {:error, Error.new(:design_log_failed)}
      end
    end
  end

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
