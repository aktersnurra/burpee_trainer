defmodule BurpeeTrainer.Coach do
  @moduledoc "Creates and refines verified user-scoped workout drafts."

  alias BurpeeTrainer.{Accounts, Workouts}

  alias BurpeeTrainer.Coach.{
    Client,
    Context,
    PhasedWorkoutDefinition,
    Policy,
    WorkoutGuidance,
    WorkoutRequest
  }

  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan}

  require Logger

  @authoring_max_graphemes 500
  @authoring_max_bytes 4_000
  @feedback_event_limit 512
  @feedback_max_seconds 86_400

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

  defp revise_home_workout(user, expected, instruction, opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, source} <- Workouts.verify_home_selection(user, expected),
         {:ok, context} <- Context.ensure_session(user, source, Context.home_key(expected)) do
      author_attempt(user, source, context, text, opts, fn definition, attempt ->
        Workouts.commit_home_revision(user, expected, definition, text, context.id, attempt)
      end)
    end
  end

  @spec prepare_home_bootstrap(Accounts.User.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_home_bootstrap(user, slot, request, opts \\ [])

  def prepare_home_bootstrap(%Accounts.User{} = user, %{slot_key: slot_key} = slot, text, opts)
      when is_binary(slot_key) and is_binary(text) and is_list(opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(text),
         :ok <- current_bootstrap_slot(user, slot),
         {:ok, context} <- Context.ensure_session(user, nil, "home-bootstrap:" <> slot_key) do
      prepare_request(user, nil, context, text, %{kind: :bootstrap, slot: slot}, opts)
    end
  end

  def prepare_home_bootstrap(%Accounts.User{}, _slot, _text, _opts),
    do: {:error, Error.new(:invalid_workout_definition)}

  @spec prepare_home_revision(Accounts.User.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_home_revision(user, expected, instruction, opts \\ []) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, source} <- Workouts.verify_home_selection(user, expected),
         {:ok, context} <- Context.ensure_session(user, source, Context.home_key(expected)) do
      prepare_request(user, source, context, text, %{kind: :revision, expected: expected}, opts)
    end
  end

  @spec confirm_home_bootstrap(Accounts.User.t(), map(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  def confirm_home_bootstrap(user, prepared, opts \\ [])

  def confirm_home_bootstrap(
        %Accounts.User{id: user_id} = user,
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
    with :ok <- current_bootstrap_slot(user, slot),
         {:ok, context} <- Context.ensure_session(user, nil, "home-bootstrap:" <> slot.slot_key),
         true <- context.id == context_id do
      bootstrap_home_draft(user, slot, text, Keyword.put(opts, :confirmed_request, request))
    else
      _ -> {:error, Error.new(:design_workspace_changed)}
    end
  end

  def confirm_home_bootstrap(%Accounts.User{}, _prepared, _opts),
    do: {:error, Error.new(:design_workspace_changed)}

  @spec confirm_home_revision(Accounts.User.t(), map(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  def confirm_home_revision(user, prepared, opts \\ [])

  def confirm_home_revision(
        %Accounts.User{id: user_id} = user,
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
    with {:ok, source} <- Workouts.verify_home_selection(user, expected),
         {:ok, context} <- Context.ensure_session(user, source, Context.home_key(expected)),
         true <- context.id == context_id do
      revise_home_workout(user, expected, text, Keyword.put(opts, :confirmed_request, request))
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, Error.new(:design_workspace_changed)}
    end
  end

  def confirm_home_revision(%Accounts.User{}, _prepared, _opts),
    do: {:error, Error.new(:design_workspace_changed)}

  @doc "Compile and audit a review candidate without creating a WorkoutPlan."
  @spec prepare_plan(Accounts.User.t(), String.t(), WorkoutRequest.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_plan(user, instruction, request, opts \\ [])

  def prepare_plan(%Accounts.User{} = user, instruction, %WorkoutRequest{} = request, opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, request} <- WorkoutRequest.new(WorkoutRequest.to_map(request)),
         :ok <- validate_review_budget(request),
         {:ok, review_source, reference_messages} <-
           review_source(user, Keyword.get(opts, :edit_source)),
         {:ok, context} <-
           Context.ensure_session(
             user,
             nil,
             Keyword.get(opts, :workspace_key, "plan-review:" <> Ecto.UUID.generate())
           ) do
      opts =
        opts
        |> Keyword.put(:confirmed_request, request)
        |> Keyword.put(:prepare_review, true)
        |> Keyword.put(:source_reference_messages, reference_messages)

      author_attempt(user, nil, context, text, opts, fn canonical, attempt ->
        with {:ok, definition} <- WorkoutDefinition.new(canonical),
             {:ok, chosen} <- review_request(request, definition),
             {:ok, chosen} <- complete_review_request(chosen, definition) do
          prepared = %{
            user_id: user.id,
            context_id: context.id,
            attempt: attempt,
            approval_attempt: Ecto.UUID.generate(),
            definition: canonical,
            request: chosen,
            original_request: request,
            source: review_source,
            text: text,
            alternative?: chosen.timed_rests != request.timed_rests
          }

          with {:ok, _} <-
                 Context.append(user, context.id, attempt, :outcome, %{
                   "status" => "prepared",
                   "review" => review_payload(prepared)
                 }),
               do: {:ok, prepared}
        end
      end)
    end
  end

  def prepare_plan(%Accounts.User{}, _, _, _),
    do: {:error, Error.new(:invalid_workout_definition)}

  @doc "Save the audited candidate once, without provider or Home selection writes."
  @spec approve_plan(Accounts.User.t(), map(), keyword()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def approve_plan(user, prepared, opts \\ [])

  def approve_plan(
        %Accounts.User{id: user_id} = user,
        %{
          user_id: user_id,
          context_id: id,
          attempt: attempt,
          approval_attempt: approval_attempt,
          definition: %{},
          text: text,
          alternative?: alternative?,
          request: %WorkoutRequest{},
          original_request: %WorkoutRequest{}
        } = prepared,
        opts
      )
      when is_binary(text) and is_boolean(alternative?) and is_list(opts) do
    BurpeeTrainer.Repo.immediate_transaction(fn ->
      with :ok <- Context.check_source(user, id, nil),
           {:ok, entries} <- Context.entries(user, id),
           %{attempt_id: ^attempt} <-
             entries |> Enum.filter(&(&1.kind == :instruction)) |> List.last(),
           %{payload: %{"review" => audited}} <-
             Enum.find(
               entries,
               &(&1.attempt_id == attempt and &1.kind == :outcome and
                   &1.payload["status"] == "prepared")
             ),
           true <- audited == review_payload(prepared),
           :ok <- verify_review_source(user, Map.get(prepared, :source)),
           :ok <- alternative_confirmation(prepared, opts),
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
              user,
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

  def approve_plan(%Accounts.User{}, _, _), do: {:error, Error.new(:design_workspace_changed)}

  defp alternative_confirmation(%{alternative?: true}, opts) do
    if Keyword.get(opts, :accept_alternative, false),
      do: :ok,
      else: {:error, Error.new(:alternative_confirmation_required)}
  end

  defp alternative_confirmation(_, _), do: :ok

  defp review_payload(prepared) do
    %{
      "approval_attempt" => prepared.approval_attempt,
      "definition" => prepared.definition,
      "request" => WorkoutRequest.to_map(prepared.request),
      "original_request" => WorkoutRequest.to_map(prepared.original_request),
      "source" => Map.get(prepared, :source),
      "text" => prepared.text,
      "alternative" => prepared.alternative?
    }
  end

  defp review_source(_user, nil), do: {:ok, nil, []}

  defp review_source(user, %{id: id, content_hash: hash}) do
    with {:ok, source} <- Workouts.design_source(user, id),
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

  defp verify_review_source(user, %{"plan_id" => id, "content_hash" => hash}) do
    case review_source(user, %{id: id, content_hash: hash}) do
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

  defp review_request(request, definition) do
    case WorkoutRequest.validate_definition(request, definition) do
      :ok ->
        {:ok, request}

      {:error, _, _} ->
        with {:ok, core} <-
               WorkoutRequest.new(Map.put(WorkoutRequest.to_map(request), "timed_rests", [])),
             :ok <- WorkoutRequest.validate_definition(core, definition),
             rests <-
               definition.events
               |> WorkoutRequest.rest_timeline()
               |> Enum.filter(fn {_, duration} -> rem(duration, 1_000_000) == 0 end),
             {:ok, chosen} <- choose_review_rests(request.timed_rests, rests, []),
             {:ok, alternative} <-
               WorkoutRequest.new(Map.put(WorkoutRequest.to_map(request), "timed_rests", chosen)),
             :ok <- WorkoutRequest.validate_definition(alternative, definition) do
          {:ok, alternative}
        else
          _ -> {:error, Error.new(:invalid_workout_definition)}
        end
    end
  end

  defp choose_review_rests([], _available, chosen), do: {:ok, Enum.reverse(chosen)}

  defp choose_review_rests([wanted | remaining], available, chosen) do
    case Enum.min_by(
           available,
           fn {start, duration} ->
             abs(start / 1_000_000 - wanted.start_sec) +
               abs(duration / 1_000_000 - wanted.duration_sec)
           end,
           fn -> nil end
         ) do
      nil ->
        {:error, :no_rest_alternative}

      {start, duration} = rest ->
        following = Enum.drop_while(available, &(&1 != rest)) |> Enum.drop(1)

        value = %{
          "start_sec" => round(start / 1_000_000),
          "duration_sec" => div(duration, 1_000_000)
        }

        choose_review_rests(remaining, following, [value | chosen])
    end
  end

  @spec bootstrap_home_draft(Accounts.User.t(), map(), String.t(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.HomeSelection.t()} | {:error, Error.t()}
  defp bootstrap_home_draft(user, slot, request, opts)

  defp bootstrap_home_draft(
         %Accounts.User{} = user,
         %{slot_key: slot_key} = slot,
         request,
         opts
       )
       when is_binary(slot_key) and is_binary(request) and is_list(opts) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(request),
         {:ok, context} <- Context.ensure_session(user, nil, "home-bootstrap:" <> slot_key) do
      author_attempt(user, nil, context, text, opts, fn definition, attempt ->
        Workouts.commit_home_bootstrap(user, slot, definition, text, context.id, attempt)
      end)
    end
  end

  defp bootstrap_home_draft(%Accounts.User{}, _slot, _request, _opts),
    do: {:error, Error.new(:invalid_workout_definition)}

  defp prepare_request(user, source, context, text, scope, opts) do
    attempt = Ecto.UUID.generate()

    result =
      with {:ok, _} <-
             Context.append(user, context.id, attempt, :instruction, %{"text" => text}),
           {:ok, messages} <-
             Context.messages(user, context.id, source, attempt, @request_extraction_prompt),
           {:ok, response} <-
             Client.complete(messages, Keyword.put(opts, :response_kind, :workout_request)),
           {:ok, request} <- WorkoutRequest.new(response),
           {:ok, _} <-
             Context.append(user, context.id, attempt, :proposal, %{
               "request_spec" => WorkoutRequest.to_map(request)
             }),
           {:ok, _} <-
             Context.append(user, context.id, attempt, :outcome, %{"status" => "accepted"}) do
        {:ok,
         %{
           request: request,
           text: text,
           context_id: context.id,
           user_id: user.id,
           scope: scope
         }}
      end

    case result do
      {:error, %Error{} = error} = failure ->
        _ =
          Context.append(user, context.id, attempt, :outcome, %{
            "status" => "failed",
            "code" => Atom.to_string(error.code)
          })

        failure

      other ->
        other
    end
  end

  defp author_attempt(user, source, context, text, opts, commit) do
    attempt = Ecto.UUID.generate()

    with {:ok, _} <- Context.append(user, context.id, attempt, :instruction, %{"text" => text}) do
      result =
        safe_authoring(fn ->
          with {:ok, messages} <-
                 Context.messages(
                   user,
                   context.id,
                   source,
                   attempt,
                   WorkoutGuidance.system_prompt(user, :definition),
                   confirmed_request_message(opts)
                 ),
               {:ok, proposal} <-
                 Client.complete(
                   messages,
                   Keyword.put(opts, :response_kind, :workout_definition)
                 ),
               {:ok, _} <-
                 Context.append(user, context.id, attempt, :proposal, %{"definition" => proposal}) do
            case validate_provider_definition(proposal, Keyword.fetch!(opts, :confirmed_request)) do
              {:ok, definition} ->
                commit.(WorkoutDefinition.canonical_map(definition), attempt)

              {:error, error, detail} ->
                detail =
                  case Keyword.get(opts, :confirmed_request) do
                    %WorkoutRequest{} = request ->
                      detail <> PhasedWorkoutDefinition.phase_feedback(request, proposal)

                    _ ->
                      detail
                  end

                {:needs_correction, error, proposal,
                 correction_feedback(
                   detail,
                   feedback_proposal(proposal, opts),
                   Keyword.fetch!(opts, :confirmed_request)
                 )}
            end
          end
        end)

      case result do
        {:needs_correction, error, proposal, detail} ->
          case Context.append(user, context.id, attempt, :outcome, %{
                 "status" => "failed",
                 "code" => Atom.to_string(error.code)
               }) do
            {:ok, _} ->
              correct_definition(
                user,
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
          record_failed_outcome(user, context.id, attempt, other)
      end
    end
  end

  defp correct_definition(
         user,
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
           Context.append(user, context.id, attempt, :instruction, %{
             "text" => text,
             "repair_of" => failed_attempt
           }) do
      correction = %{
        role: "user",
        content:
          Jason.encode!(%{
            scope: "timeline_correction",
            instruction: text,
            validation: detail,
            rejected_definition: proposal,
            confirmed_request: confirmed_request_map(opts),
            rule:
              "One correction only. Keep requested reps, duration, and rest constraints. Return a complete replacement definition with exact totals. Use a sustainable movement pace; allocate available time to explicit between-set rest events instead of slowing reps to fill the clock. Never add rests if the user asked for no rest."
          })
      }

      result =
        safe_authoring(fn ->
          with {:ok, messages} <-
                 Context.messages(
                   user,
                   context.id,
                   source,
                   attempt,
                   WorkoutGuidance.system_prompt(user, :definition),
                   confirmed_request_message(opts) ++ [correction]
                 ),
               {:ok, corrected} <-
                 Client.complete(
                   messages,
                   Keyword.put(opts, :response_kind, :workout_definition)
                 ),
               {:ok, _} <-
                 Context.append(user, context.id, attempt, :proposal, %{"definition" => corrected}) do
            case validate_provider_definition(corrected, Keyword.fetch!(opts, :confirmed_request)) do
              {:ok, definition} ->
                commit.(WorkoutDefinition.canonical_map(definition), attempt)

              {:error, error, detail} ->
                if Keyword.get(opts, :prepare_review, false) do
                  with {:ok, flattened} <-
                         flatten_provider_definition(
                           corrected,
                           Keyword.fetch!(opts, :confirmed_request)
                         ),
                       {:ok, definition} <- WorkoutDefinition.new(flattened),
                       {:ok, definition} <- validate_compiled_definition(definition),
                       {:ok, chosen} <-
                         review_request(Keyword.fetch!(opts, :confirmed_request), definition),
                       true <-
                         chosen.timed_rests !=
                           Keyword.fetch!(opts, :confirmed_request).timed_rests,
                       :ok <-
                         validate_default_movement_pace(
                           definition,
                           Keyword.fetch!(opts, :confirmed_request)
                         ) do
                    commit.(WorkoutDefinition.canonical_map(definition), attempt)
                  else
                    _ ->
                      {:error,
                       %{error | context: Map.put(error.context || %{}, :diagnostic, detail)}}
                  end
                else
                  {:error, error}
                end
            end
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

  defp current_bootstrap_slot(user, slot) do
    with {:ok, current} <- Policy.required_slot(user, DateTime.utc_now(:second)),
         true <- current.slot_key == slot.slot_key and current.slot_date == slot.slot_date,
         :workout_needed <- current.home_state,
         {:ok, :bootstrap} <- Workouts.home_entry_state(user, current),
         nil <- Workouts.current_started_session(user) do
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

  defp validate_provider_definition(provider_definition, %WorkoutRequest{} = request) do
    with {:ok, flattened} <- flatten_provider_definition(provider_definition, request) do
      case WorkoutDefinition.new(flattened) do
        {:ok, definition} ->
          with {:ok, definition} <- validate_compiled_definition(definition),
               :ok <- WorkoutRequest.validate_definition(request, definition),
               :ok <- validate_default_movement_pace(definition, request) do
            {:ok, definition}
          end

        {:error, %Error{} = error} ->
          reject_provider_definition(:schema, error)
      end
    else
      {:error, %Error{} = error} -> reject_provider_definition(:schema, error)
    end
  end

  defp flatten_provider_definition(proposal, %WorkoutRequest{} = request) do
    flattened =
      if PhasedWorkoutDefinition.use_phases?(request),
        do: PhasedWorkoutDefinition.flatten(request, proposal),
        else: {:ok, proposal}

    case flattened do
      {:ok, definition} -> {:ok, reconcile_actual_duration(definition, request)}
      error -> error
    end
  end

  defp flatten_provider_definition(proposal, _request), do: {:ok, proposal}

  defp reconcile_actual_duration(definition, request) do
    with true <- definition["target_duration_sec"] == request.target_duration_sec,
         {:ok, totals} <- timeline_arithmetic(definition),
         actual_us = totals.work_us + totals.rest_us,
         true <- rem(actual_us, 1_000_000) == 0,
         true <-
           abs(actual_us - request.target_duration_sec * 1_000_000) <=
             WorkoutRequest.timing_tolerance_sec() * 1_000_000 do
      Map.put(definition, "target_duration_sec", div(actual_us, 1_000_000))
    else
      _ -> definition
    end
  end

  defp confirmed_request_message(opts) do
    messages =
      case Keyword.get(opts, :confirmed_request) do
        %WorkoutRequest{} = request ->
          [
            %{
              role: "system",
              content:
                Jason.encode!(%{
                  scope: "confirmed_workout_request",
                  request: WorkoutRequest.to_map(request),
                  rule:
                    if(PhasedWorkoutDefinition.use_phases?(request),
                      do:
                        "These user-confirmed constraints are authoritative. Follow the phased response schema: phase_1 and each subsequent phase_N has work_rest_pairs of work plus positive rest_after, followed by last_work; each rest_N is mandatory between phases. The model chooses sets, cadence, and flexible rest durations. Phase work plus flexible recovery must total #{inspect(PhasedWorkoutDefinition.phase_budgets(request))} seconds in order when fixed anchors are present. The mandatory rests begin at their exact elapsed seconds. Do not echo a different target or describe rests only in rationale.",
                      else:
                        "These user-confirmed constraints are authoritative. Encode timed rests as events starting at their exact elapsed seconds. Do not echo a different target."
                    )
                })
            }
          ]

        _missing ->
          []
      end

    messages ++ Keyword.get(opts, :source_reference_messages, [])
  end

  defp confirmed_request_map(opts) do
    case Keyword.get(opts, :confirmed_request) do
      %WorkoutRequest{} = request -> WorkoutRequest.to_map(request)
      _missing -> nil
    end
  end

  defp feedback_proposal(%{} = proposal, opts) do
    case Keyword.get(opts, :confirmed_request) do
      %WorkoutRequest{} = request ->
        proposal =
          case flatten_provider_definition(proposal, request) do
            {:ok, flattened} -> flattened
            {:error, _} -> proposal
          end

        proposal
        |> Map.put("target_reps", request.target_reps)
        |> Map.put("target_duration_sec", request.target_duration_sec)

      _missing ->
        proposal
    end
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

  defp correction_feedback(detail, %{"events" => events} = proposal, %WorkoutRequest{} = request)
       when is_list(events) do
    rest_count = Enum.count(events, &(is_map(&1) and &1["kind"] == "rest"))

    {arithmetic, rep_advice, time_advice} =
      case timeline_arithmetic(proposal) do
        {:ok, totals} ->
          rep_advice =
            if totals.work_reps == totals.target_reps,
              do: "Keep the rep count fixed and",
              else: "Correct the rep count first, then"

          target_us = totals.target_duration_sec * 1_000_000

          time_advice =
            cond do
              totals.work_us > target_us ->
                "work alone exceeds the target; use only an allowed pace or report infeasibility"

              totals.work_us + totals.rest_us > target_us ->
                "reduce flexible rest without moving required timed rests"

              true ->
                "allocate remaining time to explicit between-set rest events"
            end

          {format_timeline_arithmetic(totals, proposal, request), rep_advice, time_advice}

        :error ->
          {"", "Recalculate the rep count and", "encode requested recovery explicitly"}
      end

    advice =
      if request.recovery == "required" do
        " #{rep_advice} recompute the rest budget; #{time_advice}. Preserve requested timed " <>
          "rest starts and durations; do not slow reps to fill the clock."
      else
        " If the user requests no rest, do not add rest events. Keep explicit pace constraints."
      end

    detail <> arithmetic <> " rest_events=#{rest_count}." <> advice
  end

  defp correction_feedback(detail, _proposal, _request), do: detail

  defp timeline_arithmetic(%{
         "events" => events,
         "target_reps" => target_reps,
         "target_duration_sec" => target_duration_sec
       })
       when is_list(events) and is_integer(target_reps) and target_reps > 0 and
              target_reps <= 100_000 and is_integer(target_duration_sec) and
              target_duration_sec > 0 and target_duration_sec <= @feedback_max_seconds do
    if events == [] or length(events) > @feedback_event_limit do
      :error
    else
      terminal_index = length(events) - 1

      events
      |> Enum.with_index()
      |> Enum.reduce_while(
        {:ok,
         %{
           target_reps: target_reps,
           target_duration_sec: target_duration_sec,
           work_reps: 0,
           work_us: 0,
           rest_us: 0,
           adjacent_work_sets: 0,
           previous_work?: false,
           uniform_pace_us: nil
         }},
        fn
          {%{"kind" => "work", "reps" => reps, "sec_per_rep" => pace, "sec_per_burpee" => active},
           index},
          {:ok, totals}
          when is_integer(reps) and reps > 0 and reps <= 100_000 and is_number(pace) and
                 pace > 0 and pace <= @feedback_max_seconds and is_number(active) and
                 active > 0 and active <= pace ->
            pace_us = round(pace * 1_000_000)
            active_us = round(active * 1_000_000)

            if pace_us > 0 and active_us > 0 do
              duration_us =
                if index == terminal_index,
                  do: (reps - 1) * pace_us + active_us,
                  else: reps * pace_us

              uniform_pace_us =
                case totals.uniform_pace_us do
                  nil -> {pace_us, active_us}
                  {^pace_us, ^active_us} -> {pace_us, active_us}
                  _mixed -> :mixed
                end

              {:cont,
               {:ok,
                %{
                  totals
                  | work_reps: totals.work_reps + reps,
                    work_us: totals.work_us + duration_us,
                    adjacent_work_sets:
                      totals.adjacent_work_sets + if(totals.previous_work?, do: 1, else: 0),
                    previous_work?: true,
                    uniform_pace_us: uniform_pace_us
                }}}
            else
              {:halt, :error}
            end

          {%{"kind" => "rest", "duration_sec" => seconds}, _index}, {:ok, totals}
          when is_number(seconds) and seconds > 0 and seconds <= @feedback_max_seconds ->
            duration_us = round(seconds * 1_000) * 1_000

            if duration_us > 0 do
              {:cont,
               {:ok, %{totals | rest_us: totals.rest_us + duration_us, previous_work?: false}}}
            else
              {:halt, :error}
            end

          _event, _totals ->
            {:halt, :error}
        end
      )
    end
  end

  defp timeline_arithmetic(_proposal), do: :error

  defp format_timeline_arithmetic(totals, proposal, request) do
    accounted_us = totals.work_us + totals.rest_us
    gap_us = totals.target_duration_sec * 1_000_000 - accounted_us

    gap =
      if gap_us >= 0,
        do: " missing_sec=#{format_seconds(gap_us)}",
        else: " excess_sec=#{format_seconds(-gap_us)}"

    target_rest_budget = target_rest_budget(totals, proposal, request)

    " work_reps=#{totals.work_reps} target_reps=#{totals.target_reps}" <>
      " work_sec=#{format_seconds(totals.work_us)} rest_sec=#{format_seconds(totals.rest_us)}" <>
      " accounted_sec=#{format_seconds(accounted_us)}#{gap}#{target_rest_budget}" <>
      " adjacent_work_sets_without_rest=#{totals.adjacent_work_sets}"
  end

  defp target_rest_budget(totals, proposal, request) do
    case totals.uniform_pace_us do
      {pace_us, active_us} ->
        default_range =
          case proposal["burpee_type"] do
            "six_count" -> WorkoutGuidance.default_active_seconds_range(:six_count)
            "navy_seal" -> WorkoutGuidance.default_active_seconds_range(:navy_seal)
            _other -> nil
          end

        reference_pace_us =
          case default_range do
            {fastest, slowest} ->
              if request.recovery == "required" and is_nil(request.requested_pace_sec) and
                   (pace_us < round(fastest * 1_000_000) or
                      pace_us > round(slowest * 1_000_000) or
                      active_us < round(fastest * 1_000_000) or
                      active_us > round(slowest * 1_000_000)),
                 do: round(slowest * 1_000_000),
                 else: nil

            _missing ->
              nil
          end

        {label, target_work_us} =
          if reference_pace_us do
            {"rest_budget_at_reference_pace_sec", totals.target_reps * reference_pace_us}
          else
            terminal_adjustment = if totals.previous_work?, do: active_us - pace_us, else: 0
            {"rest_budget_at_target_reps_sec", totals.target_reps * pace_us + terminal_adjustment}
          end

        rest_budget_us = totals.target_duration_sec * 1_000_000 - target_work_us

        if rest_budget_us >= 0,
          do: " #{label}=#{format_seconds(rest_budget_us)}",
          else: " target_reps_infeasible_at_proposed_pace=true"

      _mixed_or_missing ->
        ""
    end
  end

  defp format_seconds(microseconds) do
    if rem(microseconds, 1_000_000) == 0,
      do: Integer.to_string(div(microseconds, 1_000_000)),
      else: microseconds |> Kernel./(1_000_000) |> Float.round(6) |> Float.to_string()
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
