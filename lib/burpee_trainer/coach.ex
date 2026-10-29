defmodule BurpeeTrainer.Coach do
  @moduledoc "Creates and refines verified user-scoped workout drafts."

  alias BurpeeTrainer.{Accounts, Workouts}

  alias BurpeeTrainer.Coach.{
    Client,
    AuthoringPrompt,
    WorkoutLayout,
    RestFitter,
    WorkoutGuidance,
    WorkoutRequest
  }

  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan}

  require Logger

  @doc """
  Whether the app's own coach (its model) runs for the scope's user: granted by a Pocket
  ID claim at sign-in. Without it the user coaches through Claude and no model call is
  made for them (`Coach.Client.chat/2` refuses).
  """
  @spec enabled?(Accounts.Scope.t()) :: boolean()
  def enabled?(%Accounts.Scope{user: %Accounts.User{coach_enabled: enabled?}}),
    do: enabled? != false

  def enabled?(_scope), do: false

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
         {:ok, source} <- Workouts.verify_home_selection(scope, expected) do
      author_attempt(scope, source, text, opts, fn definition ->
        Workouts.commit_home_revision(
          scope,
          expected,
          definition,
          text
        )
      end)
    end
  end

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
         {:ok, source} <- Workouts.verify_home_selection(scope, expected) do
      prepare_request(scope, source, text, %{kind: :revision, expected: expected}, opts)
    end
  end

  @doc """
  Reads a follow-up instruction against the proposal being refined, not the workout the
  design started from, so each turn builds on the last.
  """
  @spec prepare_refinement(Accounts.Scope.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_refinement(
        %Accounts.Scope{} = scope,
        %{} = base_definition,
        instruction,
        opts \\ []
      ) do
    with :ok <- outside_authoring_transaction(),
         {:ok, text} <- validate_authoring_input(instruction),
         {:ok, prepared} <-
           prepare_request(
             scope,
             %{definition_json: base_definition},
             text,
             %{kind: :refinement},
             opts
           ) do
      {:ok, carry_max_set(prepared, Keyword.get(opts, :max_set_reps))}
    end
  end

  # What the athlete limited a set to stays limited unless they say otherwise, and while it
  # still fits the reps.
  defp carry_max_set(%{request: %WorkoutRequest{max_set_reps: nil} = request} = prepared, max)
       when is_integer(max) and max >= 1 and max <= request.target_reps,
       do: %{prepared | request: %{request | max_set_reps: max}}

  defp carry_max_set(prepared, _max), do: prepared

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
          text: text
        },
        opts
      )
      when is_list(opts) do
    with {:ok, _source} <- Workouts.verify_home_selection(scope, expected) do
      revise_home_workout(scope, expected, text, Keyword.put(opts, :confirmed_request, request))
    end
  end

  def confirm_home_revision(%Accounts.Scope{}, _prepared, _opts),
    do: {:error, Error.new(:design_workspace_changed)}

  @doc """
  Reads the New form's note into exact sets, fixed pauses and recovery. The fields the
  owner entered stay as entered; a blank note asks the coach nothing.
  """
  @spec prepare_new_request(Accounts.Scope.t(), WorkoutRequest.t(), String.t(), keyword()) ::
          {:ok, WorkoutRequest.t()} | {:error, Error.t()}
  def prepare_new_request(
        %Accounts.Scope{} = scope,
        %WorkoutRequest{} = request,
        note,
        opts \\ []
      )
      when is_binary(note),
      do: new_request(scope, request, String.trim(note), opts)

  defp new_request(_scope, request, "" = _note, _opts), do: {:ok, request}

  defp new_request(scope, request, note, opts) do
    fixed = %{
      role: "user",
      content:
        Jason.encode!(%{
          scope: "fixed_fields",
          request: WorkoutRequest.to_map(request),
          rule:
            "These fields are fixed. From the instruction take only set_reps, timed_rests and recovery."
        })
    }

    messages = AuthoringPrompt.messages(scope, nil, note, @request_extraction_prompt, [fixed])

    with :ok <- outside_authoring_transaction(),
         {:ok, %{content: %{} = response, tool_calls: []}} <-
           Client.chat(
             messages,
             chat_opts(
               scope,
               opts,
               "new_request",
               {"workout_request", WorkoutRequest.json_schema()}
             )
           ) do
      request
      |> WorkoutRequest.to_map()
      |> Map.merge(Map.take(response, ~w[set_reps timed_rests recovery]))
      |> WorkoutRequest.new()
      |> case do
        {:ok, request} -> {:ok, request}
        {:error, _} -> {:error, Error.new(:note_does_not_fit)}
      end
    else
      {:error, error} -> {:error, error}
      _ -> {:error, Error.new(:invalid_provider_response)}
    end
  end

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
         {:ok, review_source, source_messages} <-
           review_source(scope, Keyword.get(opts, :edit_source)) do
      reference_messages =
        refinement_messages(Keyword.get(opts, :base_definition), source_messages)

      opts =
        opts
        |> Keyword.put(:confirmed_request, request)
        |> Keyword.put(:prepare_review, true)
        |> Keyword.put(:source_reference_messages, reference_messages)

      author_attempt(scope, nil, text, opts, fn canonical ->
        with {:ok, definition} <- WorkoutDefinition.new(canonical),
             {:ok, chosen} <- complete_review_request(request, definition) do
          prepared = %{
            user_id: user.id,
            approval_key: Ecto.UUID.generate(),
            definition: canonical,
            request: chosen,
            original_request: request,
            source: review_source,
            text: text
          }

          {:ok, prepared}
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
        %Accounts.Scope{user: %{id: user_id}} = scope,
        %{
          user_id: user_id,
          approval_key: key,
          definition: %{} = canonical,
          request: %WorkoutRequest{} = request,
          original_request: %WorkoutRequest{},
          text: text
        } = prepared,
        opts
      )
      when is_binary(text) and is_binary(key) and is_list(opts) do
    BurpeeTrainer.Repo.immediate_transaction(fn ->
      with :ok <- verify_review_source(scope, Map.get(prepared, :source)),
           {:ok, definition} <- WorkoutDefinition.new(canonical),
           {:ok, definition} <- validate_compiled_definition(definition),
           {:ok, request} <- WorkoutRequest.new(WorkoutRequest.to_map(request)),
           :ok <- validate_review_budget(request),
           :ok <- WorkoutRequest.validate_definition(request, definition),
           :ok <- WorkoutRequest.validate_definition(prepared.original_request, definition),
           {:ok, plan} <-
             Workouts.commit_approved_workout(scope, canonical, text, approval_key: key) do
        plan
      else
        {:error, %Error{} = error} -> BurpeeTrainer.Repo.rollback(error)
        _ -> BurpeeTrainer.Repo.rollback(Error.new(:invalid_workout_definition))
      end
    end)
  end

  def approve_plan(%Accounts.Scope{}, _, _), do: {:error, Error.new(:design_workspace_changed)}

  @doc "Publish a reviewed workout and select it atomically; never starts a session."
  def approve_and_select_plan(scope, prepared, expected) do
    BurpeeTrainer.Repo.immediate_transaction(fn ->
      with {:ok, _} <- Workouts.verify_home_selection(scope, expected),
           {:ok, plan} <- approve_plan(scope, prepared),
           {:ok, selected} <- Workouts.select_home_workout(scope, expected, plan.id) do
        selected
      else
        {:error, error} -> BurpeeTrainer.Repo.rollback(error)
      end
    end)
  end

  # A refinement builds on the proposal the athlete is looking at; the workout the design
  # started from stays the provenance (`review_source`) but is no longer the reference.
  defp refinement_messages(nil, source_messages), do: source_messages

  defp refinement_messages(%{} = base, _source_messages) do
    [
      %{
        role: "system",
        content:
          Jason.encode!(%{
            scope: "current_proposal",
            definition: base,
            rule:
              "The athlete is refining this proposal. Keep everything they did not ask to change; the confirmed fields are authoritative. Redistribute ordinary recovery within the new movement budget; preserve exact supplied ordered sets and timed pauses. Update the name if the workout's character changed. Never modify the original."
          })
      }
    ]
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

  defp prepare_request(%Accounts.Scope{user: user} = scope, source, text, request_scope, opts) do
    messages = AuthoringPrompt.messages(scope, source, text, @request_extraction_prompt, [])

    with {:ok, %{content: response, tool_calls: []}} <-
           Client.chat(
             messages,
             chat_opts(
               scope,
               opts,
               "edit_request",
               {"workout_request", WorkoutRequest.json_schema()}
             )
           ),
         {:ok, request} <- WorkoutRequest.new(response) do
      {:ok, %{request: request, text: text, user_id: user.id, scope: request_scope}}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, Error.new(:invalid_provider_response)}
    end
  end

  defp author_attempt(scope, source, text, opts, commit) do
    opts = Keyword.put_new_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    messages =
      AuthoringPrompt.messages(
        scope,
        source,
        text,
        WorkoutGuidance.system_prompt(scope),
        layout_messages(opts)
      )

    with {:ok, %{content: proposal, tool_calls: []}} <-
           Client.chat(
             messages,
             chat_opts(
               scope,
               opts,
               "layout",
               {"workout_layout",
                WorkoutLayout.json_schema(Keyword.fetch!(opts, :confirmed_request))}
             )
           ) do
      case build_definition(Keyword.fetch!(opts, :confirmed_request), proposal) do
        {:ok, definition} ->
          commit.(WorkoutDefinition.canonical_map(definition))

        {:error, _error, detail} ->
          correct_definition(scope, source, text, opts, commit, proposal, detail)
      end
    else
      {:error, error} -> {:error, error}
      _ -> {:error, Error.new(:invalid_provider_response)}
    end
  end

  defp correct_definition(scope, source, text, opts, commit, proposal, detail) do
    correction = %{
      role: "user",
      content:
        Jason.encode!(%{
          scope: "layout_correction",
          rejected_layout: proposal,
          problem: detail,
          rule:
            "One correction only. Change sets, reps, pace or weights so the layout fits. Keep every confirmed constraint. Rest durations are computed for you."
        })
    }

    messages =
      AuthoringPrompt.messages(
        scope,
        source,
        text,
        WorkoutGuidance.system_prompt(scope),
        layout_messages(opts) ++ [correction]
      )

    with {:ok, %{content: corrected, tool_calls: []}} <-
           Client.chat(
             messages,
             chat_opts(
               scope,
               opts,
               "layout",
               {"workout_layout",
                WorkoutLayout.json_schema(Keyword.fetch!(opts, :confirmed_request))}
             )
           ) do
      case build_definition(Keyword.fetch!(opts, :confirmed_request), corrected) do
        {:ok, definition} ->
          commit.(WorkoutDefinition.canonical_map(definition))

        {:error, error, detail} ->
          {:error, %{error | context: Map.put(error.context, :diagnostic, detail)}}
      end
    else
      {:error, error} -> {:error, error}
      _ -> {:error, Error.new(:invalid_provider_response)}
    end
  end

  defp chat_opts(scope, opts, purpose, format),
    do:
      opts
      |> Keyword.take([:req, :config, :budget])
      |> Keyword.merge(
        response_format: format,
        ledger: %{
          scope: scope,
          purpose: purpose,
          run_id: Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)
        }
      )

  defp outside_authoring_transaction do
    if BurpeeTrainer.Repo.in_transaction?(),
      do: {:error, Error.new(:authoring_transaction_forbidden)},
      else: :ok
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
              "These constraints are authoritative. Return a layout with exactly #{length(request.timed_rests) + 1} phases; fixed pauses sit between phases and are not part of the layout. Rest durations are computed from your weights." <>
                max_set_rule(request)
          })
      }
    ] ++ Keyword.get(opts, :source_reference_messages, [])
  end

  defp max_set_rule(%WorkoutRequest{max_set_reps: nil}), do: ""

  defp max_set_rule(%WorkoutRequest{max_set_reps: max}),
    do: " No set may have more than #{max} reps; use more, smaller sets instead."

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
