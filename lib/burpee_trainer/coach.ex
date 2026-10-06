defmodule BurpeeTrainer.Coach do
  @moduledoc "Creates and refines verified user-scoped workout drafts."

  alias BurpeeTrainer.{Accounts, Workouts}

  alias BurpeeTrainer.Coach.{
    Client,
    Context,
    Policy,
    RestFitter,
    WorkoutGuidance,
    WorkoutRequest
  }

  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan}

  require Logger

  @authoring_max_graphemes 500
  @authoring_max_bytes 4_000

  @request_extraction_prompt """
  Extract one concrete workout request from the user's active instruction and supplied workout context.
  Return only the requested JSON fields. The user will review your interpretation before a plan is made.
  Set concrete rep and duration targets even for open-ended instructions, using the existing workout,
  level, and comparable training history as context. Do not invent measured personal movement pace.
  Convert every fixed rest to its elapsed start and duration in seconds; a rest at minute 11 begins
  at 660 seconds. Recovery between sets is different from pauses within an unbroken set.
  Choose required recovery if the user asks for rests, forbidden only when they prohibit rests,
  otherwise optional. Set requested_pace_sec for an explicit seconds-per-rep request;
  when editing recovery on an existing workout, inherit its active movement pace unless
  the user asks to change it. Do not treat a block length as movement pace.
  In recovery-allocation instructions, roughly minute-long sets mean work plus ordinary recovery,
  not sixty seconds of active work, unless the user explicitly specifies work-only duration.
  Keep approximate block lengths and even-rest preferences in the active instruction for planning;
  do not invent exact ordered set_reps from those approximate preferences. Extract exact ordered
  set_reps only when the user explicitly supplies or asks to preserve that sequence.
  """

  defp revise_home_workout(scope, expected, instruction, opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, source} <- Workouts.verify_home_selection(scope, expected),
         {:ok, context} <- Context.ensure_session(scope, source, Context.home_key(expected)) do
      author_attempt(scope, source, context, text, opts, fn definition, attempt ->
        Workouts.commit_home_revision(
          scope,
          expected,
          definition,
          text,
          context.id,
          attempt
        )
      end)
    end
  end

  @spec prepare_home_bootstrap(Accounts.Scope.t(), map(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec prepare_home_bootstrap(Accounts.Scope.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_home_bootstrap(scope, slot, request, opts \\ [])

  def prepare_home_bootstrap(
        %Accounts.Scope{user: %Accounts.User{}} = scope,
        %{slot_key: slot_key} = slot,
        text,
        opts
      )
      when is_binary(slot_key) and is_binary(text) and is_list(opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(text),
         :ok <- current_bootstrap_slot(scope, slot),
         {:ok, context} <- Context.ensure_session(scope, nil, "home-bootstrap:" <> slot_key) do
      prepare_request(scope, nil, context, text, %{kind: :bootstrap, slot: slot}, opts)
    end
  end

  def prepare_home_bootstrap(%Accounts.Scope{}, _slot, _text, _opts),
    do: {:error, Error.new(:invalid_workout_definition)}

  @spec prepare_home_revision(Accounts.Scope.t(), map(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec prepare_home_revision(Accounts.Scope.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_home_revision(
        %Accounts.Scope{user: %Accounts.User{}} = scope,
        expected,
        instruction,
        opts \\ []
      ) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, source} <- Workouts.verify_home_selection(scope, expected),
         {:ok, context} <- Context.ensure_session(scope, source, Context.home_key(expected)) do
      prepare_request(scope, source, context, text, %{kind: :revision, expected: expected}, opts)
    end
  end

  @spec confirm_home_bootstrap(Accounts.Scope.t(), map()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  @spec confirm_home_bootstrap(Accounts.Scope.t(), map(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  def confirm_home_bootstrap(scope, prepared, opts \\ [])

  def confirm_home_bootstrap(
        %Accounts.Scope{user: %Accounts.User{id: user_id}} = scope,
        %{
          user_id: user_id,
          scope: %{kind: :bootstrap, slot: slot},
          request: %WorkoutRequest{} = request,
          text: text,
          context_id: context_id
        },
        opts
      )
      when is_list(opts) do
    with :ok <- current_bootstrap_slot(scope, slot),
         {:ok, context} <- Context.ensure_session(scope, nil, "home-bootstrap:" <> slot.slot_key),
         true <- context.id == context_id do
      bootstrap_home_draft(scope, slot, text, Keyword.put(opts, :confirmed_request, request))
    else
      _ -> {:error, Error.new(:design_workspace_changed)}
    end
  end

  def confirm_home_bootstrap(%Accounts.Scope{}, _prepared, _opts),
    do: {:error, Error.new(:design_workspace_changed)}

  @spec confirm_home_revision(Accounts.Scope.t(), map()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  @spec confirm_home_revision(Accounts.Scope.t(), map(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  def confirm_home_revision(scope, prepared, opts \\ [])

  def confirm_home_revision(
        %Accounts.Scope{user: %Accounts.User{id: user_id}} = scope,
        %{
          user_id: user_id,
          scope: %{kind: :revision, expected: expected},
          request: %WorkoutRequest{} = request,
          text: text,
          context_id: context_id
        },
        opts
      )
      when is_list(opts) do
    with {:ok, source} <- Workouts.verify_home_selection(scope, expected),
         {:ok, context} <- Context.ensure_session(scope, source, Context.home_key(expected)),
         true <- context.id == context_id do
      revise_home_workout(scope, expected, text, Keyword.put(opts, :confirmed_request, request))
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, Error.new(:design_workspace_changed)}
    end
  end

  def confirm_home_revision(%Accounts.Scope{}, _prepared, _opts),
    do: {:error, Error.new(:design_workspace_changed)}

  @doc "Compile and audit a review candidate without creating a WorkoutPlan."
  @spec prepare_plan(Accounts.Scope.t(), String.t(), WorkoutRequest.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec prepare_plan(Accounts.Scope.t(), String.t(), WorkoutRequest.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_plan(scope, instruction, request, opts \\ [])

  def prepare_plan(
        %Accounts.Scope{user: %Accounts.User{} = user} = scope,
        instruction,
        %WorkoutRequest{} = request,
        opts
      ) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, request} <- WorkoutRequest.new(WorkoutRequest.to_map(request)),
         :ok <- validate_review_budget(request),
         {:ok, review_source, reference_messages} <-
           review_source(scope, Keyword.get(opts, :edit_source)),
         {:ok, context} <-
           Context.ensure_session(
             scope,
             nil,
             Keyword.get(opts, :workspace_key, "plan-review:" <> Ecto.UUID.generate())
           ) do
      opts =
        opts
        |> Keyword.put(:confirmed_request, request)
        |> Keyword.put(:prepare_review, true)
        |> Keyword.put(:source_reference_messages, reference_messages)

      author_attempt(scope, nil, context, text, opts, fn canonical, attempt ->
        with {:ok, definition} <- WorkoutDefinition.new(canonical),
             {:ok, chosen} <- complete_review_request(request, definition) do
          prepared = %{
            user_id: user.id,
            context_id: context.id,
            attempt: attempt,
            approval_attempt: Ecto.UUID.generate(),
            definition: canonical,
            request: chosen,
            original_request: request,
            source: review_source,
            text: text
          }

          with {:ok, _} <-
                 Context.append(scope, context.id, attempt, :outcome, %{
                   "status" => "prepared",
                   "review" => review_payload(prepared)
                 }),
               do: {:ok, prepared}
        end
      end)
    end
  end

  def prepare_plan(%Accounts.Scope{}, _, _, _),
    do: {:error, Error.new(:invalid_workout_definition)}

  @doc "Save the audited candidate once, without provider or Home selection writes."
  @spec approve_plan(Accounts.Scope.t(), map()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  @spec approve_plan(Accounts.Scope.t(), map(), keyword()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def approve_plan(scope, prepared, opts \\ [])

  def approve_plan(
        %Accounts.Scope{user: %Accounts.User{id: user_id} = user} = scope,
        %{
          user_id: user_id,
          context_id: id,
          attempt: attempt,
          approval_attempt: approval_attempt,
          definition: %{},
          text: text,
          request: %WorkoutRequest{},
          original_request: %WorkoutRequest{}
        } = prepared,
        opts
      )
      when is_binary(text) and is_list(opts) do
    BurpeeTrainer.Repo.immediate_transaction(fn ->
      with :ok <- Context.check_source(scope, id, nil),
           {:ok, entries} <- Context.entries(scope, id),
           %{attempt_id: ^attempt} <-
             entries |> Enum.filter(&(&1.kind == :instruction)) |> List.last(),
           %{payload: %{"review" => audited}} <-
             Enum.find(
               entries,
               &(&1.attempt_id == attempt and &1.kind == :outcome and
                   &1.payload["status"] == "prepared")
             ),
           true <- audited == review_payload(prepared),
           :ok <- verify_review_source(scope, Map.get(prepared, :source)),
           {:ok, definition} <- WorkoutDefinition.new(prepared.definition),
           {:ok, definition} <- validate_compiled_definition(definition),
           :ok <- WorkoutRequest.validate_definition(prepared.request, definition) do
        accepted =
          Enum.find(
            entries,
            &(&1.attempt_id == approval_attempt and &1.kind == :outcome and
                &1.payload["status"] == "accepted")
          )

        result =
          if accepted do
            case BurpeeTrainer.Repo.get_by(WorkoutPlan,
                   id: accepted.payload["workout_plan_id"],
                   user_id: user.id
                 ) do
              %WorkoutPlan{} = plan ->
                if plan.content_hash == accepted.payload["content_hash"] and
                     plan.definition_json == prepared.definition,
                   do: {:ok, plan},
                   else: {:error, Error.new(:design_workspace_changed)}

              _ ->
                {:error, Error.new(:design_workspace_changed)}
            end
          else
            Workouts.commit_approved_workout(
              scope,
              prepared.definition,
              prepared.text,
              id,
              approval_attempt
            )
          end

        case result do
          {:ok, plan} -> plan
          {:error, error} -> BurpeeTrainer.Repo.rollback(error)
        end
      else
        {:error, %Error{} = error} -> BurpeeTrainer.Repo.rollback(error)
        _ -> BurpeeTrainer.Repo.rollback(Error.new(:design_workspace_changed))
      end
    end)
    |> tap(fn
      {:ok, plan} -> Workouts.Finalization.notify(plan)
      _ -> :ok
    end)
  end

  def approve_plan(%Accounts.Scope{}, _, _), do: {:error, Error.new(:design_workspace_changed)}

  defp review_payload(prepared) do
    %{
      "approval_attempt" => prepared.approval_attempt,
      "definition" => prepared.definition,
      "request" => WorkoutRequest.to_map(prepared.request),
      "original_request" => WorkoutRequest.to_map(prepared.original_request),
      "source" => Map.get(prepared, :source),
      "text" => prepared.text
    }
  end

  defp review_source(_user, nil), do: {:ok, nil, []}

  defp review_source(scope, %{id: id, content_hash: hash}) do
    with {:ok, source} <- Workouts.design_source(scope, id),
         :ok <- Workouts.verify_plan_content(source),
         true <- source.content_hash == hash do
      reference = %{
        role: "system",
        content:
          Jason.encode!(%{
            scope: "edit_workout_source",
            definition: source.definition_json,
            rule:
              "The user explicitly chose to edit this workout into a new variation. Keep its character where feasible, but the confirmed fields are authoritative. Redistribute ordinary recovery within the new movement budget; preserve exact supplied ordered sets and timed pauses. Update the name for the revised workout. Never modify the original."
          })
      }

      {:ok, %{"plan_id" => id, "content_hash" => hash}, [reference]}
    else
      _ -> {:error, Error.new(:design_workspace_changed)}
    end
  end

  defp review_source(_, _), do: {:error, Error.new(:design_workspace_changed)}
  defp verify_review_source(_user, nil), do: :ok

  defp verify_review_source(scope, %{"plan_id" => id, "content_hash" => hash}) do
    case review_source(scope, %{id: id, content_hash: hash}) do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp verify_review_source(_, _), do: {:error, Error.new(:design_workspace_changed)}

  defp validate_review_budget(request) do
    case BurpeeTrainer.Coach.WorkoutConfiguration.budget(
           request.target_reps,
           request.requested_pace_sec,
           request.target_duration_sec
         ) do
      {:ok, _} -> :ok
      _ -> {:error, Error.new(:invalid_workout_definition, %{field: :requested_pace_sec})}
    end
  end

  defp complete_review_request(request, definition) do
    work = Enum.filter(definition.events, &(&1.kind == :work))

    pace =
      case Enum.uniq_by(work, & &1.sec_per_burpee) do
        [event] -> event.sec_per_burpee
        _ -> nil
      end

    attrs =
      WorkoutRequest.to_map(request)
      |> Map.put("set_reps", Enum.map(work, & &1.reps))
      |> Map.put("requested_pace_sec", request.requested_pace_sec || pace)

    movement_us = Enum.reduce(work, 0, &(&2 + &1.reps * round(&1.sec_per_burpee * 1_000_000)))

    with true <- movement_us <= request.target_duration_sec * 1_000_000,
         {:ok, complete} <- WorkoutRequest.new(attrs),
         :ok <- WorkoutRequest.validate_definition(complete, definition) do
      {:ok, complete}
    else
      _ -> {:error, Error.new(:invalid_workout_definition, %{field: :requested_pace_sec})}
    end
  end

  @spec bootstrap_home_draft(Accounts.Scope.t(), map(), String.t(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  defp bootstrap_home_draft(user, slot, request, opts)

  defp bootstrap_home_draft(
         %Accounts.Scope{user: %Accounts.User{}} = scope,
         %{slot_key: slot_key} = slot,
         request,
         opts
       )
       when is_binary(slot_key) and is_binary(request) and is_list(opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(request),
         {:ok, context} <- Context.ensure_session(scope, nil, "home-bootstrap:" <> slot_key) do
      author_attempt(scope, nil, context, text, opts, fn definition, attempt ->
        Workouts.commit_home_bootstrap(
          scope,
          slot,
          definition,
          text,
          context.id,
          attempt
        )
      end)
    end
  end

  defp bootstrap_home_draft(%Accounts.Scope{}, _slot, _request, _opts),
    do: {:error, Error.new(:invalid_workout_definition)}

  defp prepare_request(
         %Accounts.Scope{user: user} = scope,
         source,
         context,
         text,
         request_scope,
         opts
       ) do
    attempt = Ecto.UUID.generate()

    result =
      with {:ok, _} <-
             Context.append(scope, context.id, attempt, :instruction, %{"text" => text}),
           {:ok, messages} <-
             Context.messages(scope, context.id, source, attempt, @request_extraction_prompt),
           {:ok, response} <-
             Client.complete(messages, Keyword.put(opts, :response_kind, :workout_request)),
           {:ok, request} <- WorkoutRequest.new(response),
           {:ok, _} <-
             Context.append(scope, context.id, attempt, :proposal, %{
               "request_spec" => WorkoutRequest.to_map(request)
             }),
           {:ok, _} <-
             Context.append(scope, context.id, attempt, :outcome, %{"status" => "accepted"}) do
        {:ok,
         %{
           request: request,
           text: text,
           context_id: context.id,
           user_id: user.id,
           scope: request_scope
         }}
      end

    case result do
      {:error, %Error{} = error} = failure ->
        _ =
          Context.append(scope, context.id, attempt, :outcome, %{
            "status" => "failed",
            "code" => Atom.to_string(error.code)
          })

        failure

      other ->
        other
    end
  end

  defp author_attempt(scope, source, context, text, opts, commit) do
    attempt = Ecto.UUID.generate()

    with {:ok, _} <- Context.append(scope, context.id, attempt, :instruction, %{"text" => text}) do
      result =
        safe_authoring(fn ->
          with {:ok, messages} <-
                 Context.messages(
                   scope,
                   context.id,
                   source,
                   attempt,
                   WorkoutGuidance.system_prompt(scope),
                   layout_messages(opts)
                 ),
               {:ok, proposal} <-
                 Client.complete(messages, Keyword.put(opts, :response_kind, :workout_layout)),
               {:ok, _} <-
                 Context.append(scope, context.id, attempt, :proposal, %{"layout" => proposal}) do
            case build_definition(Keyword.fetch!(opts, :confirmed_request), proposal) do
              {:ok, definition} ->
                commit.(WorkoutDefinition.canonical_map(definition), attempt)

              {:error, error, detail} ->
                {:needs_correction, error, proposal, detail}
            end
          end
        end)

      case result do
        {:needs_correction, error, proposal, detail} ->
          case Context.append(scope, context.id, attempt, :outcome, %{
                 "status" => "failed",
                 "code" => Atom.to_string(error.code)
               }) do
            {:ok, _} ->
              correct_definition(
                scope,
                source,
                context,
                text,
                opts,
                commit,
                attempt,
                proposal,
                detail
              )

            {:error, _} ->
              {:error, error}
          end

        other ->
          record_failed_outcome(scope, context.id, attempt, other)
      end
    end
  end

  defp correct_definition(
         scope,
         source,
         context,
         text,
         opts,
         commit,
         failed_attempt,
         proposal,
         detail
       ) do
    attempt = Ecto.UUID.generate()

    with {:ok, _} <-
           Context.append(scope, context.id, attempt, :instruction, %{
             "text" => text,
             "repair_of" => failed_attempt
           }) do
      correction = %{
        role: "user",
        content:
          Jason.encode!(%{
            scope: "layout_correction",
            rejected_layout: proposal,
            problem: detail,
            rule:
              "One correction only. Change sets, reps per set, pace or weights so the layout fits. Keep every confirmed constraint. Rest durations are computed for you."
          })
      }

      result =
        safe_authoring(fn ->
          with {:ok, messages} <-
                 Context.messages(
                   scope,
                   context.id,
                   source,
                   attempt,
                   WorkoutGuidance.system_prompt(scope),
                   layout_messages(opts) ++ [correction]
                 ),
               {:ok, corrected} <-
                 Client.complete(messages, Keyword.put(opts, :response_kind, :workout_layout)),
               {:ok, _} <-
                 Context.append(scope, context.id, attempt, :proposal, %{"layout" => corrected}) do
            case build_definition(Keyword.fetch!(opts, :confirmed_request), corrected) do
              {:ok, definition} ->
                commit.(WorkoutDefinition.canonical_map(definition), attempt)

              {:error, error, detail} ->
                {:error, %{error | context: Map.put(error.context || %{}, :diagnostic, detail)}}
            end
          end
        end)

      record_failed_outcome(scope, context.id, attempt, result)
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

  defp record_failed_outcome(scope, id, attempt, {:error, %Error{} = error} = original) do
    recorded =
      try do
        Context.append(scope, id, attempt, :outcome, %{
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

  defp current_bootstrap_slot(scope, slot) do
    with {:ok, current} <- Policy.required_slot(scope, DateTime.utc_now(:second)),
         true <- current.slot_key == slot.slot_key and current.slot_date == slot.slot_date,
         :workout_needed <- current.home_state,
         {:ok, :bootstrap} <- Workouts.home_entry_state(scope, current),
         nil <- Workouts.current_started_session(scope) do
      :ok
    else
      _ -> {:error, Error.new(:design_workspace_changed)}
    end
  end

  defp validate_authoring_input(input) when is_binary(input) do
    input = String.trim(input)

    if input != "" and String.length(input) <= @authoring_max_graphemes and
         byte_size(input) <= @authoring_max_bytes do
      {:ok, input}
    else
      {:error, Error.new(:invalid_workout_definition)}
    end
  end

  defp build_definition(%WorkoutRequest{} = request, layout) do
    case RestFitter.fit(request, layout) do
      {:ok, attrs} ->
        with {:ok, definition} <- WorkoutDefinition.new(attrs),
             {:ok, definition} <- validate_compiled_definition(definition),
             :ok <- WorkoutRequest.validate_definition(request, definition),
             :ok <- validate_default_movement_pace(definition, request) do
          {:ok, definition}
        else
          {:error, %Error{} = error, detail} ->
            {:error, error, detail}

          {:error, %Error{} = error} ->
            reject_provider_definition(:schema, error)

          {:error, reason, details} ->
            {:error, Error.new(:invalid_workout_definition),
             "validation #{inspect({reason, details})}"}

          _ ->
            {:error, Error.new(:invalid_workout_definition), "validation failed"}
        end

      {:error, reason} ->
        {:error, Error.new(:infeasible_workout_definition, %{reason: elem(reason, 0)}),
         RestFitter.describe(reason)}
    end
  end

  defp layout_messages(opts) do
    request = Keyword.fetch!(opts, :confirmed_request)

    [
      %{
        role: "system",
        content:
          Jason.encode!(%{
            scope: "confirmed_workout_request",
            request: WorkoutRequest.to_map(request),
            rule:
              "These constraints are authoritative. Return a layout with exactly #{length(request.timed_rests) + 1} phases; fixed pauses sit between phases and are not part of the layout. Rest durations are computed from your weights."
          })
      }
    ] ++ Keyword.get(opts, :source_reference_messages, [])
  end

  defp validate_default_movement_pace(definition, %WorkoutRequest{} = request) do
    {fastest, slowest} = WorkoutGuidance.default_active_seconds_range(definition.burpee_type)

    outside_reference? =
      Enum.any?(definition.events, fn
        %{kind: :work, sec_per_burpee: active} -> active < fastest or active > slowest
        %{kind: :rest} -> false
      end)

    if request.recovery == "required" and is_nil(request.requested_pace_sec) and
         outside_reference? do
      {:error, Error.new(:invalid_workout_definition),
       "field=events movement_pace_outside_default_reference_sec_per_rep=#{fastest}-#{slowest}; use between-set rest rather than an artificially fast or slow movement pace"}
    else
      :ok
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

    safe_error =
      if error.code == :infeasible_workout_definition,
        do: Error.new(:infeasible_workout_definition),
        else: Error.new(:invalid_workout_definition)

    safe_field = if is_atom(field), do: Atom.to_string(field), else: "definition"
    detail = "phase=#{phase} field=#{safe_field}#{arithmetic}#{safe_duration_gap(error.context)}"
    {:error, safe_error, detail}
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

  defp safe_duration_gap(%{value: %{actual_us: actual, expected_us: expected}})
       when is_integer(actual) and is_integer(expected) do
    difference = (expected - actual) / 1_000_000

    if difference >= 0,
      do: " missing_duration_sec=#{difference}",
      else: " excess_duration_sec=#{abs(difference)}"
  end

  defp safe_duration_gap(_context), do: ""
end
