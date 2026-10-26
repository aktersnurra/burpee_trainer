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
    HomeLive
  }

  # Selected-workspace events cannot act without a persisted selection.

  def handle_event("change_adjustment", _params, %{assigns: %{home_selection: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("submit_home_action", _params, %{assigns: %{home_selection: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("edit_current_workout", _, socket) do
    if not is_nil(socket.assigns.home_selection) and socket.assigns.expanded? and
         socket.assigns.authoring_stage == :idle do
      case Workouts.verify_home_selection(
             socket.assigns.current_scope,
             socket.assigns.home_selection
           ) do
        {:ok, source} ->
          params = HomeWorkoutRequest.from_definition(source.definition_json)

          {:noreply,
           socket
           |> step({:edit_opened, source, params, "variation:#{Ecto.UUID.generate()}"})
           |> adjustment_form("")
           |> workout_form(params, %{})}

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

  def handle_event("new_workout", _, socket) do
    if socket.assigns.expanded? and socket.assigns.authoring_stage == :idle and
         socket.assigns.home_selection do
      current =
        HomeWorkoutRequest.from_definition(socket.assigns.home_selection.plan.definition_json)

      params = %{current | pace: nil}

      {:noreply,
       socket
       |> step({:new_opened, params, "creator:#{Ecto.UUID.generate()}"})
       |> workout_form(params, %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("abort_new_workout", _, socket) do
    {:noreply,
     socket
     |> step(:aborted)
     |> assign(swap_preview: nil)
     |> HomeLive.assign_home()
     |> HomeWorkspace.refresh_projection()}
  end

  def handle_event("change_new_workout", %{"home_workout" => attrs}, socket) do
    if socket.assigns.authoring_stage in [:new, :editing],
      do:
        {:noreply,
         socket
         |> step(:preparation_discarded)
         |> workout_form(socket.assigns.workout_parameters, attrs)},
      else: {:noreply, socket}
  end

  def handle_event("choose_workout_value", %{"field" => field, "value" => value}, socket)
      when field in ["burpee_type", "pacing_style"] do
    if socket.assigns.authoring_stage in [:new, :editing] do
      attrs = Map.put(socket.assigns.workout_form.params, field, value)

      {:noreply,
       socket
       |> step(:preparation_discarded)
       |> workout_form(socket.assigns.workout_parameters, attrs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "review_new_workout",
        %{"home_workout" => attrs},
        %{assigns: %{authoring_stage: stage}} = socket
      )
      when stage in [:new, :editing] do
    begin_plan_review(socket, attrs)
  end

  def handle_event("edit_workout_request", _, %{assigns: %{authoring_stage: :review}} = socket) do
    params = socket.assigns.workout_parameters

    {:noreply,
     socket
     |> step(:editing_resumed)
     |> workout_form(params, %{})}
  end

  def handle_event(
        "save_workout_request",
        %{"home_workout" => attrs},
        %{assigns: %{authoring_stage: :editing}} = socket
      ) do
    begin_plan_review(socket, attrs)
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

      socket
      |> step({:review_prepared, id, prepared, params, prepared_inspection(prepared)})
      |> workout_form(params, %{})
    end
  end

  defp settle(:new_request, id, {:ok, {:error, error}}, socket) do
    {message, field, field_message} = review_failure(error)

    socket =
      step(
        socket,
        {:review_failed, id,
         if(socket.assigns.editing_source && field_message, do: field_message, else: message)}
      )

    if field do
      changeset =
        Ecto.Changeset.add_error(socket.assigns.workout_form.source, field, field_message)

      params =
        Map.put(
          changeset.params || %{},
          Atom.to_string(field),
          socket.assigns.workout_form[field].value
        )

      assign(socket,
        workout_form: to_form(%{changeset | action: :validate, params: params}, as: :home_workout)
      )
    else
      socket
    end
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

  defp workout_form(socket, params, attrs) do
    changeset = HomeWorkoutRequest.changeset(params, attrs)

    assign(socket,
      workout_parameters: Ecto.Changeset.apply_changes(changeset),
      workout_form: to_form(changeset, as: :home_workout)
    )
  end

  defp review_failure(%{code: code})
       when code in [:provider_unavailable, :provider_timeout, :invalid_provider_response],
       do: {"Coach unavailable. Try again later; your current workout is unchanged.", nil, nil}

  defp review_failure(%{code: :note_does_not_fit}),
    do:
      {"Your note doesn't add up with the reps and duration above. Change one, then Review again; your current workout is unchanged.",
       :note, "This doesn't add up with the reps and duration above."}

  defp review_failure(%{
         context: %{field: :set_reps, actual_count: actual, expected_count: expected}
       }) do
    {"The returned plan changed your ordered set pattern. Edit or Review again; your current workout is unchanged.",
     :note, "Returned #{actual} sets; expected #{expected}. The ordered rep sequence must match."}
  end

  defp review_failure(%{
         context: %{field: :timed_rests, start_sec: start, duration_sec: duration}
       }) do
    {"The returned plan missed #{duration}s at #{CreationParameters.duration_label(start)}. Try a different time or shorter pause, then Review again; your current workout is unchanged.",
     :note, "Returned plan did not meet this total pause."}
  end

  defp review_failure(%{context: %{field: :requested_pace_sec}}),
    do:
      {"Returned movement time exceeds the requested duration. Edit or Review again; your current workout is unchanged.",
       :pace, "Returned movement time exceeds the requested duration."}

  defp review_failure(_),
    do:
      {"The returned plan did not meet your constraints. Check the sets and pauses you asked for, then Review again; your current workout is unchanged.",
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
       |> workout_form(params, %{})
       |> start_async({:new_request, id}, fn ->
         with {:ok, request} <- Coach.prepare_new_request(scope, request, params.note || "") do
           Coach.prepare_plan(scope, text, request, workspace_key: key, edit_source: source)
         end
       end)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, workout_form: to_form(changeset, as: :home_workout))}

      {:error, :selection_changed} ->
        {:noreply,
         assign(socket, local_error: "That workout changed. Abort and open Edit again.")}

      _ ->
        {:noreply, assign(socket, local_error: "Check the reps, duration and pace.")}
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

  def adjustment_form(socket, text),
    do:
      assign(socket,
        adjustment_form:
          to_form(HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => text}))
      )
end
