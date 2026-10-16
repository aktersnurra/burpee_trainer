defmodule BurpeeTrainerWeb.HomeAuthoring do
  @moduledoc "Authoring responsibility of the shared Home workspace; ordinary module."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.{Coach, Workouts}

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
           |> assign(
             authoring_stage: :editing,
             authoring_returned?: false,
             editing_source: source,
             workout_parameters: params,
             creation_key: "variation:#{Ecto.UUID.generate()}",
             created_plan: nil,
             pending_request: nil,
             instruction: "",
             local_error: nil
           )
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
    {:noreply,
     socket |> discard_preparation() |> assign(instruction: text) |> adjustment_form(text)}
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
         |> discard_preparation()
         |> assign(busy?: true, update_id: id, instruction: text)
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
    if socket.assigns.expanded? and socket.assigns.authoring_stage == :idle do
      params = %HomeWorkoutRequest{}

      {:noreply,
       socket
       |> assign(
         authoring_stage: :new,
         authoring_returned?: false,
         editing_source: nil,
         workout_parameters: params,
         creation_key: "creator:#{Ecto.UUID.generate()}",
         created_plan: nil,
         pending_request: nil,
         local_error: nil
       )
       |> workout_form(params, %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("abort_new_workout", _, socket) do
    {:noreply,
     socket
     |> discard_preparation()
     |> assign(
       authoring_stage: :idle,
       created_plan: nil,
       local_error: nil,
       # Only New takes the workout away; Edit keeps it in view, so nothing returns.
       authoring_returned?: is_nil(socket.assigns.editing_source)
     )}
  end

  def handle_event("change_new_workout", %{"home_workout" => attrs}, socket) do
    if socket.assigns.authoring_stage in [:new, :editing],
      do:
        {:noreply,
         socket |> discard_preparation() |> workout_form(socket.assigns.workout_parameters, attrs)},
      else: {:noreply, socket}
  end

  def handle_event("choose_workout_value", %{"field" => field, "value" => value}, socket)
      when field in ["burpee_type", "pacing_style"] do
    if socket.assigns.authoring_stage in [:new, :editing] do
      attrs = Map.put(socket.assigns.workout_form.params, field, value)

      {:noreply,
       socket |> discard_preparation() |> workout_form(socket.assigns.workout_parameters, attrs)}
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
     |> discard_preparation()
     |> assign(authoring_stage: :editing)
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
       |> assign(authoring_stage: :idle, created_plan: nil)
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
           |> assign(busy?: true, update_id: id, instruction: text, local_error: nil)
           |> start_async({:home_revision_request, id}, fn ->
             Coach.prepare_home_revision(scope, expected, instruction)
           end)}
      end
    else
      _ ->
        {:noreply, assign(socket, local_error: "Enter an adjustment of at most 500 characters.")}
    end
  end

  def handle_event("confirm_workout_request", _, %{assigns: %{authoring_stage: :review}} = socket) do
    a = socket.assigns
    id = make_ref()
    scope = a.current_scope
    prepared = a.pending_request

    if prepared && verify_edit_selection(socket) == :ok do
      {:noreply,
       socket
       |> assign(busy?: true, update_id: id, local_error: nil)
       |> start_async({:new_plan, id}, fn -> Coach.approve_plan(scope, prepared) end)}
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
     |> assign(busy?: true, update_id: id, local_error: nil)
     |> start_async({:home_revision, id}, fn ->
       Coach.confirm_home_revision(scope, prepared)
     end)}
  end

  def handle_event("back_to_workout_request", _params, %{assigns: %{busy?: false}} = socket) do
    {:noreply,
     socket
     |> assign(pending_request: nil, local_error: nil)
     |> adjustment_form(socket.assigns.instruction)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def handle_async(
        {:new_request, id},
        {:ok, {:ok, prepared}},
        %{assigns: %{update_id: id}} = socket
      ) do
    if verify_edit_selection(socket) != :ok do
      {:noreply,
       assign(socket,
         busy?: false,
         update_id: nil,
         pending_request: nil,
         local_error: "That workout changed. Abort and open Edit again."
       )}
    else
      params =
        HomeWorkoutRequest.from_request(prepared.request, socket.assigns.workout_parameters)

      {:noreply,
       socket
       |> assign(
         authoring_stage: :review,
         review_inspection_rows: prepared_inspection(prepared),
         pending_request: prepared,
         workout_parameters: params,
         busy?: false,
         update_id: nil
       )
       |> workout_form(params, %{})}
    end
  end

  def handle_async(
        {:new_request, id},
        {:ok, {:error, error}},
        %{assigns: %{update_id: id}} = socket
      ) do
    {message, field, field_message} = review_failure(error)

    socket =
      assign(socket,
        busy?: false,
        update_id: nil,
        pending_request: nil,
        local_error:
          if(socket.assigns.editing_source && field_message, do: field_message, else: message)
      )

    socket =
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
          workout_form:
            to_form(%{changeset | action: :validate, params: params}, as: :home_workout)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async({:new_request, id}, _, %{assigns: %{update_id: id}} = socket),
    do:
      {:noreply,
       assign(socket,
         busy?: false,
         update_id: nil,
         pending_request: nil,
         local_error: "Coach unavailable. Try again later; your current workout is unchanged."
       )}

  def handle_async({:new_plan, id}, {:ok, {:ok, plan}}, %{assigns: %{update_id: id}} = socket),
    do:
      {:noreply,
       socket
       |> assign(
         busy?: false,
         update_id: nil,
         authoring_stage: :saved,
         pending_request: nil,
         created_plan: plan
       )
       |> HomeChooser.refresh_alternatives()}

  def handle_async(
        {:new_plan, id},
        {:ok, {:error, %{code: code}}},
        %{assigns: %{update_id: id}} = socket
      )
      when code in [
             :provider_unavailable,
             :provider_timeout,
             :provider_request_failed,
             :invalid_provider_response
           ] do
    {:noreply,
     assign(socket,
       busy?: false,
       update_id: nil,
       local_error: "Coach unavailable. Try again later; your current workout is unchanged."
     )}
  end

  def handle_async({:new_plan, id}, _, %{assigns: %{update_id: id}} = socket),
    do:
      {:noreply,
       assign(socket,
         busy?: false,
         update_id: nil,
         local_error:
           "Couldn’t produce a validated plan. Update the targets or recovery and try again; your current workout is unchanged."
       )}

  def handle_async({kind, _}, _, socket) when kind in [:new_request, :new_plan],
    do: {:noreply, socket}

  def handle_async(
        {:home_revision_request, id},
        {:ok, {:ok, prepared}},
        %{assigns: %{update_id: id}} = socket
      ) do
    case Workouts.verify_home_selection(socket.assigns.current_scope, prepared.scope.expected) do
      {:ok, _plan} ->
        {:noreply,
         assign(socket, busy?: false, update_id: nil, pending_request: prepared, local_error: nil)}

      {:error, _} ->
        {:noreply,
         assign(socket,
           busy?: false,
           update_id: nil,
           pending_request: nil,
           local_error: "The training day or workout changed. Reopen Home before updating."
         )}
    end
  end

  def handle_async(
        {:home_revision_request, id},
        _result,
        %{assigns: %{update_id: id}} = socket
      ) do
    {:noreply,
     socket
     |> assign(
       busy?: false,
       update_id: nil,
       pending_request: nil,
       local_error: "Couldn’t interpret that request. Your workout is unchanged."
     )
     |> adjustment_form(socket.assigns.instruction)}
  end

  def handle_async({:home_revision_request, _id}, _result, socket), do: {:noreply, socket}

  def handle_async(
        {:home_revision, id},
        {:ok, {:ok, selected}},
        %{assigns: %{update_id: id}} = socket
      ) do
    case Workouts.verify_home_selection(socket.assigns.current_scope, selected) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> assign(busy?: false, update_id: nil)
         |> HomeWorkspace.show_selection(selected, true)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(
           busy?: false,
           update_id: nil,
           local_error:
             "The training day or workout changed. Reopen Home before starting or updating."
         )
         |> adjustment_form(socket.assigns.instruction)}
    end
  end

  def handle_async({:home_revision, id}, result, %{assigns: %{update_id: id}} = socket) do
    message =
      case result do
        {:ok, {:error, %{code: :authoring_context_too_large}}} ->
          "This design history is too large to send. Your previous workout is unchanged."

        _ ->
          "Couldn’t update. Your previous workout is unchanged."
      end

    {:noreply,
     socket
     |> assign(busy?: false, update_id: nil, pending_request: nil, local_error: message)
     |> adjustment_form(socket.assigns.instruction)
     |> HomeChooser.refresh_alternatives()}
  end

  def handle_async({:home_revision, _id}, _result, socket), do: {:noreply, socket}

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

  def discard_preparation(socket) do
    socket =
      if socket.assigns.busy? && socket.assigns.update_id,
        do: cancel_async(socket, {:new_request, socket.assigns.update_id}),
        else: socket

    assign(socket,
      pending_request: nil,
      busy?: false,
      update_id: nil,
      local_error: nil
    )
  end

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
       |> discard_preparation()
       |> workout_form(params, %{})
       |> assign(busy?: true, update_id: id, instruction: text)
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
