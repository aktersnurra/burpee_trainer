defmodule BurpeeTrainerWeb.HomeAuthoring do
  @moduledoc "Authoring responsibility of the shared Home workspace; ordinary module."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.{Coach, Workouts}
  alias BurpeeTrainerWeb.HomeAuthoring.Flow

  alias BurpeeTrainerWeb.{
    CreationParameters,
    HomeAdjustment,
    HomeWorkoutRequest,
    HomeWorkspace,
    HomeChooser,
    HomeLive,
    NewWorkoutSteps
  }

  # Selected-workspace events cannot act without a persisted selection.

  def handle_event("change_adjustment", _params, %{assigns: %{home_selection: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("submit_home_action", _params, %{assigns: %{home_selection: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("edit_current_workout", _, socket) do
    if not is_nil(socket.assigns.home_selection) and socket.assigns.authoring_stage == :idle and
         not socket.assigns.busy? do
      case Workouts.verify_home_selection(
             socket.assigns.current_scope,
             socket.assigns.home_selection
           ) do
        {:ok, source} ->
          params = HomeWorkoutRequest.from_definition(source.definition_json)

          {:noreply,
           socket
           |> step({:edit_opened, source, params, "variation:#{Ecto.UUID.generate()}"})
           |> assign(options_open?: false, workout_parameters: params)
           |> adjustment_form("")}

        _ ->
          {:noreply,
           assign(socket, local_error: "That workout changed. Reopen it before editing.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "change_current_edit",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: :editing, editing_source: source}} = socket
      )
      when not is_nil(source) and is_binary(text) do
    {:noreply, socket |> step({:instruction_changed, text}) |> adjustment_form(text)}
  end

  # While a proposal is on screen, or New's message is being written, the box holds the next
  # message: typing changes nothing else.
  def handle_event(
        "change_current_edit",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: stage}} = socket
      )
      when is_binary(text) and stage in [:review, :new],
      do: {:noreply, adjustment_form(socket, text)}

  # A follow-up reads against the proposal on screen, so the design keeps its place.
  def handle_event(
        "refine_workout",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: :review, pending_request: %{} = base, busy?: false}} =
          socket
      )
      when is_binary(text) do
    a = socket.assigns

    cond do
      not valid_instruction?(text) ->
        {:noreply,
         assign(socket,
           local_error: "Enter a change of at most 500 characters.",
           adjustment_form: adjustment_changeset(text)
         )}

      verify_edit_selection(socket) != :ok ->
        {:noreply,
         assign(socket, local_error: "That workout changed. Abort and open Edit again.")}

      true ->
        id = make_ref()
        scope = a.current_scope
        key = a.creation_key
        source = a.editing_source
        selection = a.home_selection
        text = String.trim(text)

        {:noreply,
         socket
         |> step({:refine_started, id, text})
         |> adjustment_form(text)
         |> start_async({:new_request, id}, fn ->
           with {:ok, interpreted} <-
                  Coach.prepare_refinement(scope, base.definition, text,
                    max_set_reps: base.request.max_set_reps
                  ),
                :ok <- verified(scope, source, selection) do
             Coach.prepare_plan(scope, text, interpreted.request,
               workspace_key: key,
               edit_source: source,
               base_definition: base.definition
             )
           end
         end)}
    end
  end

  def handle_event(
        "review_current_edit",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: :editing, editing_source: source}} = socket
      )
      when not is_nil(source) do
    a = socket.assigns

    cond do
      not valid_instruction?(text) ->
        {:noreply, assign(socket, local_error: "Enter a change of at most 500 characters.")}

      verify_edit_selection(socket) != :ok ->
        {:noreply,
         assign(socket, local_error: "That workout changed. Abort and open Edit again.")}

      true ->
        id = make_ref()
        scope = a.current_scope
        expected = a.home_selection
        key = a.creation_key

        {:noreply,
         socket
         |> step({:review_started, id, text})
         |> adjustment_form(text)
         |> start_async({:new_request, id}, fn ->
           with {:ok, interpreted} <- Coach.prepare_home_revision(scope, expected, text),
                {:ok, _} <- Workouts.verify_home_selection(scope, expected) do
             Coach.prepare_plan(scope, text, interpreted.request,
               workspace_key: key,
               edit_source: source
             )
           end
         end)}
    end
  end

  def handle_event("open_options", _, socket) do
    a = socket.assigns

    if a.authoring_stage == :idle and not is_nil(a.home_selection) and not a.busy? and
         not a.chooser_open?,
       do: {:noreply, assign(socket, options_open?: true)},
       else: {:noreply, socket}
  end

  def handle_event("close_options", _, socket),
    do: {:noreply, assign(socket, options_open?: false)}

  # New starts from its first question, with the week's time left deciding what it offers.
  def handle_event("new_workout", _, socket) do
    a = socket.assigns

    if a.authoring_stage == :idle and not is_nil(a.home_selection) and not a.busy? do
      current = HomeWorkoutRequest.from_definition(a.home_selection.plan.definition_json)
      params = %{current | pace: nil, note: "", recovery: "optional"}

      {:noreply,
       socket
       |> step({:new_opened, params, "creator:#{Ecto.UUID.generate()}"})
       |> assign(options_open?: false, workout_parameters: params)
       |> adjustment_form("")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("abort_new_workout", _, socket) do
    {:noreply,
     socket
     |> step(:aborted)
     |> assign(swap_preview: nil)
     |> adjustment_form("")
     |> HomeLive.assign_home()
     |> HomeWorkspace.refresh_projection()}
  end

  # The first two questions are answered by one tap each, and the next follows.
  def handle_event(
        "choose_workout_value",
        %{"field" => field, "value" => value},
        %{assigns: %{authoring_stage: :new}} = socket
      )
      when (field == "burpee_type" and value in ["six_count", "navy_seal"]) or
             (field == "pacing_style" and value in ["even", "unbroken"]) do
    params = socket.assigns.workout_parameters

    {params, next} =
      if field == "burpee_type",
        do: {%{params | burpee_type: value}, :style},
        else:
          {%{
             params
             | pacing_style: value,
               max_set_reps: if(value == "even", do: nil, else: params.max_set_reps)
           }, :duration}

    {:noreply, enter_step(socket, params, next)}
  end

  # Duration, reps and pace move one step at a time, by swipe or by button.
  def handle_event(
        "step_workout_value",
        %{"field" => field, "dir" => dir},
        %{assigns: %{authoring_stage: :new, busy?: false}} = socket
      )
      when field in ["duration", "reps", "sets", "pace"] and dir in ["up", "down"] do
    direction = String.to_existing_atom(dir)

    params =
      NewWorkoutSteps.step(
        socket.assigns.workout_parameters,
        field,
        direction,
        remaining_sec(socket)
      )

    {:noreply, assign(socket, workout_parameters: params)}
  end

  def handle_event(
        "next_new_step",
        _,
        %{assigns: %{authoring_stage: :new, new_step: step, busy?: false}} = socket
      )
      when step in [:duration, :reps, :sets, :pace] do
    params = socket.assigns.workout_parameters
    {:noreply, enter_step(socket, params, NewWorkoutSteps.next(step, params))}
  end

  # A message to add to the choices opens the chat on them; otherwise they go as they are.
  def handle_event(
        "add_new_request",
        _,
        %{assigns: %{authoring_stage: :new, new_step: :ready, busy?: false}} = socket
      ),
      do: {:noreply, enter_step(socket, socket.assigns.workout_parameters, :request)}

  # Back is one step back: from the chat to what was chosen, from a proposal to it too, and
  # from the first question out.
  def handle_event("back_new_step", _, %{assigns: %{editing_source: nil}} = socket) do
    a = socket.assigns
    params = a.workout_parameters

    cond do
      a.authoring_stage not in [:new, :review] ->
        {:noreply, socket}

      a.authoring_stage == :new and a.new_step == :type ->
        handle_event("abort_new_workout", %{}, socket)

      a.authoring_stage == :review ->
        {:noreply, socket |> step({:new_step_reopened, :ready}) |> adjustment_form("")}

      true ->
        {:noreply, step(socket, {:new_step, NewWorkoutSteps.previous(a.new_step, params)})}
    end
  end

  # Any answer can be changed; what was suggested after it is suggested again.
  def handle_event(
        "goto_new_step",
        %{"step" => name},
        %{assigns: %{editing_source: nil}} = socket
      ) do
    case NewWorkoutSteps.parse(name) do
      {:ok, step} when socket.assigns.authoring_stage in [:new, :review] ->
        {:noreply,
         socket
         |> step({:new_step_reopened, step})}

      _ ->
        {:noreply, socket}
    end
  end

  # What was chosen, sent as it is, makes the first proposal.
  def handle_event(
        "send_new_workout",
        params,
        %{assigns: %{authoring_stage: :new, new_step: :ready, busy?: false}} = socket
      )
      when params == %{} or not is_map_key(params, "home_adjustment"),
      do: begin_plan_review(socket, %{"note" => ""})

  # With a request written after the prefix, it goes with them.
  def handle_event(
        "send_new_workout",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: :new, new_step: :request, busy?: false}} = socket
      )
      when is_binary(text) do
    begin_plan_review(socket, %{"note" => HomeWorkoutRequest.note(text)})
  end

  def handle_event("select_created_workout", _, %{assigns: %{authoring_stage: :saved}} = socket) do
    a = socket.assigns

    with {:ok, _} <- Workouts.verify_home_selection(a.current_scope, a.home_selection),
         {:ok, selected} <-
           Workouts.select_home_workout(a.current_scope, a.home_selection, a.created_plan.id) do
      {:noreply,
       socket
       |> step(:created_selected)
       |> HomeWorkspace.show_selection(selected, true)}
    else
      _ ->
        {:noreply,
         assign(socket,
           local_error: "The current workout changed. Reopen Home to select your saved workout."
         )}
    end
  end

  def handle_event("change_adjustment", %{"home_adjustment" => %{"instruction" => text}}, socket)
      when is_binary(text),
      do: {:noreply, socket |> assign(instruction: text) |> adjustment_form(text)}

  def handle_event("submit_home_action", params, socket) do
    text =
      case params do
        %{"home_adjustment" => %{"instruction" => text}} -> text
        _ -> nil
      end

    a = socket.assigns

    with true <- is_nil(a.pending_request),
         true <- params["client_session_id"] == a.start_client_session_id,
         {:ok, operation} <- HomeAdjustment.operation(text) do
      case operation do
        {:start, ""} ->
          HomeLive.start_result(
            socket,
            Workouts.start_home_workout(
              a.current_scope,
              a.home_selection,
              a.start_client_session_id
            )
          )

        {:update, instruction} ->
          id = make_ref()
          scope = a.current_scope
          expected = a.home_selection

          {:noreply,
           socket
           |> step({:adjustment_started, id, text})
           |> start_async({:home_revision_request, id}, fn ->
             Coach.prepare_home_revision(scope, expected, instruction)
           end)}
      end
    else
      _ ->
        {:noreply, assign(socket, local_error: "Enter an adjustment of at most 500 characters.")}
    end
  end

  def handle_event(event, _, %{assigns: %{authoring_stage: :review}} = socket)
      when event in ["confirm_workout_request", "save_review_to_library"] do
    a = socket.assigns
    id = make_ref()
    scope = a.current_scope
    prepared = a.pending_request
    expected = a.home_selection
    kind = if event == "confirm_workout_request", do: :use_plan, else: :new_plan

    if prepared && verify_edit_selection(socket) == :ok do
      {:noreply,
       socket
       |> step({:confirm_started, id})
       |> start_async({kind, id}, fn ->
         if kind == :use_plan,
           do: Coach.approve_and_select_plan(scope, prepared, expected),
           else: Coach.approve_plan(scope, prepared)
       end)}
    else
      {:noreply, assign(socket, local_error: "That workout changed. Abort and open Edit again.")}
    end
  end

  def handle_event(
        "confirm_workout_request",
        _params,
        %{assigns: %{pending_request: %{scope: %{kind: :revision}} = prepared, busy?: false}} =
          socket
      ) do
    id = make_ref()
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> step({:confirm_started, id})
     |> start_async({:home_revision, id}, fn ->
       Coach.confirm_home_revision(scope, prepared)
     end)}
  end

  def handle_event("back_to_workout_request", _params, %{assigns: %{busy?: false}} = socket) do
    {:noreply,
     socket
     |> step(:request_reopened)
     |> adjustment_form(socket.assigns.instruction)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Each result is reported to the flow, which applies it only while it is the work in
  # flight. A late answer to discarded or superseded work reaches no clause below.

  def handle_async({kind, id}, result, socket) do
    if Flow.current?(Flow.from_assigns(socket.assigns), id),
      do: {:noreply, settle(kind, id, result, socket)},
      else: {:noreply, socket}
  end

  defp settle(:new_request, id, {:ok, {:ok, prepared}}, socket) do
    if verify_edit_selection(socket) != :ok do
      step(socket, {:review_failed, id, "That workout changed. Abort and open Edit again."})
    else
      params =
        HomeWorkoutRequest.from_request(prepared.request, socket.assigns.workout_parameters)

      # What was asked now sits above the proposal; the box is empty for the next message.
      socket
      |> step({:review_prepared, id, prepared, params, prepared_inspection(prepared)})
      |> adjustment_form("")
    end
  end

  # A refinement that fails speaks of the proposal, which stays as it was.
  defp settle(
         :new_request,
         id,
         {:ok, {:error, error}},
         %{assigns: %{pending_turn: turn}} = socket
       )
       when is_binary(turn),
       do: step(socket, {:review_failed, id, refinement_failure(error)})

  defp settle(:new_request, id, result, %{assigns: %{pending_turn: turn}} = socket)
       when is_binary(turn),
       do: step(socket, {:review_failed, id, refinement_failure(result)})

  defp settle(:new_request, id, {:ok, {:error, error}}, socket) do
    {message, _field, field_message} = review_failure(error)

    # Edit says the detail; New has no field to carry it, so it follows the message.
    text =
      cond do
        is_nil(field_message) -> message
        socket.assigns.editing_source -> field_message
        true -> message <> " " <> field_message
      end

    step(socket, {:review_failed, id, text})
  end

  defp settle(:new_request, id, _, socket),
    do:
      step(
        socket,
        {:review_failed, id,
         "Coach unavailable. Try again later; your current workout is unchanged."}
      )

  defp settle(:use_plan, id, {:ok, {:ok, selected}}, socket) do
    socket
    |> step({:plan_selected, id})
    |> HomeWorkspace.show_selection(selected, true)
  end

  defp settle(:use_plan, id, _result, socket),
    do:
      step(
        socket,
        {:plan_failed, id,
         "Couldn’t use this workout. Your selection may have changed; cancel and reopen the review."}
      )

  defp settle(:new_plan, id, {:ok, {:ok, plan}}, socket),
    do: step(socket, {:plan_saved, id, plan})

  defp settle(:new_plan, id, {:ok, {:error, %{code: code}}}, socket)
       when code in [
              :provider_unavailable,
              :provider_timeout,
              :provider_request_failed,
              :invalid_provider_response
            ],
       do:
         step(
           socket,
           {:plan_failed, id,
            "Coach unavailable. Try again later; your current workout is unchanged."}
         )

  defp settle(:new_plan, id, _, socket),
    do:
      step(
        socket,
        {:plan_failed, id,
         "Couldn’t produce a validated plan. Update the targets or recovery and try again; your current workout is unchanged."}
      )

  defp settle(:home_revision_request, id, {:ok, {:ok, prepared}}, socket) do
    case Workouts.verify_home_selection(socket.assigns.current_scope, prepared.scope.expected) do
      {:ok, _plan} ->
        step(socket, {:revision_prepared, id, prepared})

      {:error, _} ->
        step(
          socket,
          {:revision_prepare_failed, id,
           "The training day or workout changed. Reopen Home before updating."}
        )
    end
  end

  defp settle(:home_revision_request, id, _result, socket) do
    socket
    |> step(
      {:revision_prepare_failed, id,
       "Couldn’t interpret that request. Your workout is unchanged."}
    )
    |> adjustment_form(socket.assigns.instruction)
  end

  defp settle(:home_revision, id, {:ok, {:ok, selected}}, socket) do
    case Workouts.verify_home_selection(socket.assigns.current_scope, selected) do
      {:ok, _plan} ->
        socket
        |> step({:revision_applied, id})
        |> HomeWorkspace.show_selection(selected, true)

      {:error, _} ->
        socket
        |> step(
          {:revision_blocked, id,
           "The training day or workout changed. Reopen Home before starting or updating."}
        )
        |> adjustment_form(socket.assigns.instruction)
    end
  end

  defp settle(:home_revision, id, result, socket) do
    message =
      case result do
        {:ok, {:error, %{code: :authoring_context_too_large}}} ->
          "This design history is too large to send. Your previous workout is unchanged."

        _ ->
          "Couldn’t update. Your previous workout is unchanged."
      end

    socket
    |> step({:revision_failed, id, message})
    |> adjustment_form(socket.assigns.instruction)
  end

  # A step starts from what is suggested for it, given the answers so far.
  defp enter_step(socket, params, step) do
    params =
      NewWorkoutSteps.enter(params, step, socket.assigns.current_scope, remaining_sec(socket))

    socket
    |> assign(workout_parameters: params)
    |> step({:new_step, step})
    |> write_message(params, step)
  end

  # The last question leaves the chat open on a message made of the answers, with the
  # cursor on a line for anything more. What was already written there is kept.
  defp write_message(socket, params, :request) do
    written = socket.assigns.adjustment_form[:instruction].value || ""

    note =
      if String.contains?(String.downcase(written), "additional request:"),
        do: HomeWorkoutRequest.note(written),
        else: ""

    adjustment_form(socket, HomeWorkoutRequest.message(params, note))
  end

  defp write_message(socket, _params, _step), do: socket

  # What the week has left, which is all New may spend.
  defp remaining_sec(%{assigns: %{slot: %{remaining_sec: seconds}}}), do: seconds
  defp remaining_sec(_socket), do: nil

  defp refinement_failure(%{code: code})
       when code in [:provider_unavailable, :provider_timeout, :invalid_provider_response],
       do: "Coach unavailable. Try again later; your proposal is unchanged."

  defp refinement_failure(%{code: :design_workspace_changed}),
    do: "That workout changed. Abort and open Edit again."

  defp refinement_failure(_),
    do: "That change didn't fit. Try saying it another way; your proposal is unchanged."

  defp review_failure(%{code: code})
       when code in [:provider_unavailable, :provider_timeout, :invalid_provider_response],
       do: {"Coach unavailable. Try again later; your current workout is unchanged.", nil, nil}

  defp review_failure(%{code: :note_does_not_fit}),
    do:
      {"Your note doesn't add up with the reps and duration. Change one, then send again; your current workout is unchanged.",
       :note, "This doesn't add up with the reps and duration above."}

  defp review_failure(%{
         context: %{field: :set_reps, actual_count: actual, expected_count: expected}
       }) do
    {"The returned plan changed your ordered set pattern. Change something and send again; your current workout is unchanged.",
     :note, "Returned #{actual} sets; expected #{expected}. The ordered rep sequence must match."}
  end

  defp review_failure(%{
         context: %{field: :timed_rests, start_sec: start, duration_sec: duration}
       }) do
    {"The returned plan missed #{duration}s at #{CreationParameters.duration_label(start)}. Try a different time or shorter pause, then send again; your current workout is unchanged.",
     :note, "Returned plan did not meet this total pause."}
  end

  defp review_failure(%{context: %{field: :requested_pace_sec}}),
    do:
      {"Returned movement time exceeds the requested duration. Change something and send again; your current workout is unchanged.",
       :pace, "Returned movement time exceeds the requested duration."}

  defp review_failure(_),
    do:
      {"The returned plan did not meet your constraints. Check the sets and pauses you asked for, then send again; your current workout is unchanged.",
       nil, nil}

  def discard_preparation(socket), do: step(socket, :preparation_discarded)

  # One authoring transition: the pure flow decides, the socket carries it out.
  defp step(socket, event) do
    {model, commands} = Flow.update(Flow.from_assigns(socket.assigns), event)
    Enum.reduce(commands, assign(socket, Flow.to_assigns(model)), &run/2)
  end

  defp run({:cancel_async, name}, socket), do: cancel_async(socket, name)
  defp run(:refresh_alternatives, socket), do: HomeChooser.refresh_alternatives(socket)

  defp verify_edit_selection(%{assigns: %{editing_source: nil}}), do: :ok

  defp verify_edit_selection(%{assigns: %{home_selection: nil}}), do: {:error, :selection_changed}

  defp verify_edit_selection(%{assigns: assigns}) do
    source = assigns.editing_source

    case Workouts.verify_home_selection(assigns.current_scope, assigns.home_selection) do
      {:ok, %{id: id, content_hash: hash}} when id == source.id and hash == source.content_hash ->
        :ok

      _ ->
        {:error, :selection_changed}
    end
  end

  defp begin_plan_review(socket, attrs) do
    changeset = HomeWorkoutRequest.changeset(socket.assigns.workout_parameters, attrs)

    with {:ok, params} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- verify_edit_selection(socket),
         {:ok, request} <- HomeWorkoutRequest.request(params) do
      id = make_ref()
      scope = socket.assigns.current_scope
      key = socket.assigns.creation_key
      source = socket.assigns.editing_source
      text = HomeWorkoutRequest.instruction(params)

      {:noreply,
       socket
       |> step({:review_started, id, text})
       |> assign(workout_parameters: params)
       |> adjustment_form("")
       |> start_async({:new_request, id}, fn ->
         with {:ok, request} <- Coach.prepare_new_request(scope, request, params.note || "") do
           Coach.prepare_plan(scope, text, request, workspace_key: key, edit_source: source)
         end
       end)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, local_error: changeset_message(changeset))}

      {:error, :selection_changed} ->
        {:noreply,
         assign(socket, local_error: "That workout changed. Abort and open Edit again.")}

      _ ->
        {:noreply, assign(socket, local_error: "Check the reps, duration and pace.")}
    end
  end

  defp changeset_message(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end) do
      %{pace: [message | _]} -> message <> "."
      %{note: [message | _]} -> message <> "."
      _ -> "Check the reps, duration and pace."
    end
  end

  defp prepared_inspection(prepared) do
    {:ok, definition} = BurpeeTrainer.PlanCompiler.WorkoutDefinition.new(prepared.definition)
    {:ok, program} = BurpeeTrainer.PlanCompiler.compile(definition)

    BurpeeTrainer.Workouts.Inspection.rows(%BurpeeTrainer.Workouts.WorkoutPlan{
      definition_json: prepared.definition,
      program_json: BurpeeTrainer.PlanCompiler.ProgramHash.canonical_map(program),
      updated_at: DateTime.utc_now()
    })
  end

  defp valid_instruction?(prompt),
    do: String.trim(prompt) != "" and String.length(prompt) <= 500 and byte_size(prompt) <= 4_000

  # A design that began as New has no workout to re-check.
  defp verified(_scope, nil, _selection), do: :ok

  defp verified(scope, _source, selection) do
    with {:ok, _} <- Workouts.verify_home_selection(scope, selection), do: :ok
  end

  defp adjustment_changeset(text),
    do: to_form(HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => text}))

  def adjustment_form(socket, text),
    do:
      assign(socket,
        adjustment_form:
          to_form(HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => text}))
      )
end
