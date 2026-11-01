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
    NewWorkoutForm
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
           |> assign(workout_parameters: params)
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
         |> adjustment_form("")
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
         |> adjustment_form("")
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

  # New opens its form on what is suggested, with the week's time left deciding what it offers.
  def handle_event("new_workout", _, socket) do
    a = socket.assigns

    if a.authoring_stage == :idle and not is_nil(a.home_selection) and not a.busy? do
      current = HomeWorkoutRequest.from_definition(a.home_selection.plan.definition_json)
      params = %{current | pace: nil, note: "", recovery: "optional"}
      form = NewWorkoutForm.open(params, a.current_scope, remaining_sec(socket))

      {:noreply,
       socket
       |> step({:new_opened, form.params, "creator:#{Ecto.UUID.generate()}"})
       |> put_new_form(form)
       |> adjustment_form("")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("abort_new_workout", _, socket) do
    {:noreply,
     socket
     |> step(:aborted)
     |> adjustment_form("")
     |> HomeLive.assign_home()
     |> HomeWorkspace.refresh_projection()}
  end

  # A value typed or chosen in the form; the field it came from is the one that changed.
  def handle_event(
        "change_new_workout",
        %{"_target" => ["new", field], "new" => %{} = submitted},
        %{assigns: %{authoring_stage: :new, busy?: false}} = socket
      )
      when is_map_key(submitted, field) do
    form =
      NewWorkoutForm.change(
        new_form(socket),
        field,
        submitted[field],
        socket.assigns.current_scope,
        remaining_sec(socket)
      )

    {:noreply, put_new_form(socket, form)}
  end

  # Duration, reps, set size and pace move one step at a time by their buttons.
  def handle_event(
        "step_workout_value",
        %{"field" => field, "dir" => dir},
        %{assigns: %{authoring_stage: :new, busy?: false}} = socket
      )
      when field in ["duration", "reps", "sets", "pace"] and dir in ["up", "down"] do
    form =
      NewWorkoutForm.step(
        new_form(socket),
        field,
        String.to_existing_atom(dir),
        socket.assigns.current_scope,
        remaining_sec(socket)
      )

    {:noreply, put_new_form(socket, form)}
  end

  # Back from a proposal is back to the form it was made from, without it. On the form itself
  # (reached here once a request in flight is dropped) there is nothing further back to go.
  def handle_event("back_new_step", _, %{assigns: %{editing_source: nil}} = socket) do
    case socket.assigns.authoring_stage do
      :review -> {:noreply, socket |> step(:new_reopened) |> adjustment_form("")}
      _ -> {:noreply, socket}
    end
  end

  # The form as submitted, with what was typed but not yet sent, makes the first proposal.
  def handle_event(
        "send_new_workout",
        %{"new" => %{} = submitted},
        %{assigns: %{authoring_stage: :new, busy?: false}} = socket
      ) do
    form =
      NewWorkoutForm.submit(
        new_form(socket),
        submitted,
        socket.assigns.current_scope,
        remaining_sec(socket)
      )

    socket
    |> put_new_form(form)
    |> begin_plan_review(%{"note" => String.trim(form.params.note || "")})
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

  def handle_event("run_workout_request", _, %{assigns: %{authoring_stage: :review}} = socket) do
    a = socket.assigns
    id = make_ref()
    scope = a.current_scope
    prepared = a.pending_request
    expected = a.home_selection

    if prepared && verify_edit_selection(socket) == :ok do
      {:noreply,
       socket
       |> step({:confirm_started, id})
       |> start_async({:run_plan, id}, fn ->
         Coach.approve_and_select_plan(scope, prepared, expected)
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
       do:
         socket |> step({:review_failed, id, refinement_failure(error)}) |> adjustment_form(turn)

  defp settle(:new_request, id, result, %{assigns: %{pending_turn: turn}} = socket)
       when is_binary(turn),
       do:
         socket |> step({:review_failed, id, refinement_failure(result)}) |> adjustment_form(turn)

  defp settle(:new_request, id, {:ok, {:error, error}}, socket) do
    {message, _field, field_message} = review_failure(error)

    # Edit says the detail; New has no field to carry it, so it follows the message.
    text =
      cond do
        is_nil(field_message) -> message
        socket.assigns.editing_source -> field_message
        true -> message <> " " <> field_message
      end

    socket
    |> step({:review_failed, id, text})
    |> restore_edit_ask()
  end

  defp settle(:new_request, id, _, socket),
    do:
      socket
      |> step(
        {:review_failed, id,
         "Coach unavailable. Try again later; your current workout is unchanged."}
      )
      |> restore_edit_ask()

  # Run saves the proposal, makes it today's workout and starts it, the way Home's play does.
  defp settle(:run_plan, id, {:ok, {:ok, selected}}, socket) do
    socket =
      socket
      |> step({:plan_selected, id})
      |> HomeWorkspace.show_selection(selected, true)

    a = socket.assigns

    {:noreply, socket} =
      HomeLive.start_result(
        socket,
        Workouts.start_home_workout(a.current_scope, a.home_selection, a.start_client_session_id)
      )

    socket
  end

  defp settle(:run_plan, id, _result, socket),
    do:
      step(
        socket,
        {:plan_failed, id,
         "Couldn’t run this workout. Your selection may have changed; go back and try again."}
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

  # The box empties on send; an Edit ask that fails comes back to it to send again. New's first
  # ask is made from its answers, which stay as they were.
  defp restore_edit_ask(%{assigns: %{editing_source: nil}} = socket), do: socket
  defp restore_edit_ask(socket), do: adjustment_form(socket, socket.assigns.instruction)

  defp new_form(socket),
    do: %NewWorkoutForm{
      params: socket.assigns.workout_parameters,
      touched: socket.assigns.new_touched
    }

  defp put_new_form(socket, form),
    do: assign(socket, workout_parameters: form.params, new_touched: form.touched)

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

  # The definition's event indices of the sets numbered `sets` (1 for the first set).
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
