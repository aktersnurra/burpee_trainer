defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc """
  Bootstraps the immutable workout program and renders the stable DOM owned by
  the client session runtime.
  """

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{ExecutionProgram, WorkoutSession}
  alias BurpeeTrainerWeb.{CoreComponents, SessionComponents}

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

    case Workouts.get_unresolved_session(user) do
      %WorkoutSession{} = workout_session ->
        {:ok, push_navigate(socket, to: ~p"/sessions/#{workout_session.id}/resolve")}

      nil ->
        mount_plan_session(plan_id, user, socket)
    end
  end

  defp mount_plan_session(plan_id, user, socket) do
    case Integer.parse(plan_id) do
      {id, ""} ->
        plan = Workouts.get_plan!(user, id)
        {:ok, execution_program} = Workouts.compile_plan(plan)
        client_session_id = Ecto.UUID.generate()

        completion_form =
          plan
          |> blank_session()
          |> Ecto.Changeset.change()
          |> to_form()

        {:ok,
         socket
         |> assign(:plan, plan)
         |> assign(:execution_program, execution_program)
         |> assign(:serialized_program, serialize_program(execution_program))
         |> assign(:target_pace_sec, program_target_pace_sec(execution_program))
         |> assign(:summary, program_summary(execution_program))
         |> assign(:completion_form, completion_form)
         |> assign(:client_session_id, client_session_id)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/workouts")}
    end
  end

  @impl true
  def handle_event("begin_session", %{"client_session_id" => client_session_id}, socket) do
    {:reply, lifecycle_reply(begin_session(socket, client_session_id)), socket}
  end

  def handle_event("begin_session", _payload, socket) do
    {:reply, lifecycle_error_reply(:not_found), socket}
  end

  def handle_event("mark_report_pending", %{"client_session_id" => client_session_id}, socket) do
    {:reply, lifecycle_reply(mark_report_pending(socket, client_session_id)), socket}
  end

  def handle_event("mark_report_pending", _payload, socket) do
    {:reply, lifecycle_error_reply(:not_found), socket}
  end

  def handle_event("abort_session", %{"client_session_id" => client_session_id}, socket) do
    {:reply, lifecycle_reply(abort_session(socket, client_session_id)), socket}
  end

  def handle_event("abort_session", _payload, socket) do
    {:reply, lifecycle_error_reply(:not_found), socket}
  end

  def handle_event(
        "save_session",
        %{
          "workout_session" => %{"client_session_id" => client_session_id} = attrs,
          "tracking" => tracking
        },
        socket
      )
      when is_map(attrs) and is_map(tracking) do
    result =
      with :ok <- mounted_client_session?(socket, client_session_id) do
        Workouts.report_session(
          socket.assigns.current_user,
          client_session_id,
          attrs,
          tracking
        )
      end

    {:reply, save_reply(result), socket}
  end

  def handle_event("save_session", _payload, socket) do
    {:reply,
     %{
       status: "invalid",
       field_errors: %{},
       global_errors: ["Completion data is invalid."]
     }, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      navigation?={false}
      flash?={false}
    >
      <div
        id="burpee-session"
        phx-hook="SessionHook"
        phx-update="ignore"
        data-session-program={Jason.encode!(@serialized_program)}
        data-plan-id={@plan.id}
        data-program-hash={@execution_program.content_hash}
        data-client-session-id={@client_session_id}
        class="session-surface fixed inset-0 z-[60] min-h-dvh overflow-hidden bg-[var(--session-bg)] text-[var(--session-ink)]"
      >
        <SessionComponents.capture_choice hidden={false} />
        <SessionComponents.camera_status />
        <SessionComponents.camera_setup target_pace_sec={@target_pace_sec} />
        <SessionComponents.warmup_choice />
        <SessionComponents.workout_ready />
        <SessionComponents.runner summary={@summary} />
        <SessionComponents.completion_review form={@completion_form} />

        <p
          id="session-live-status"
          class="sr-only"
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp begin_session(socket, client_session_id) do
    with :ok <- mounted_client_session?(socket, client_session_id) do
      Workouts.begin_plan_session(
        socket.assigns.current_user,
        socket.assigns.plan,
        client_session_id
      )
    end
  end

  defp mark_report_pending(socket, client_session_id) do
    with :ok <- mounted_client_session?(socket, client_session_id) do
      Workouts.mark_report_pending(socket.assigns.current_user, client_session_id)
    end
  end

  defp abort_session(socket, client_session_id) do
    with :ok <- mounted_client_session?(socket, client_session_id) do
      Workouts.abort_session(socket.assigns.current_user, client_session_id)
    end
  end

  defp mounted_client_session?(socket, client_session_id) do
    if client_session_id == socket.assigns.client_session_id and
         match?({:ok, _}, Ecto.UUID.cast(client_session_id)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp lifecycle_reply({:ok, session}) do
    %{
      status: "ok",
      client_session_id: session.client_session_id,
      session_id: session.id,
      lifecycle_status: Atom.to_string(session.status)
    }
  end

  defp lifecycle_reply({:error, reason}), do: lifecycle_error_reply(reason)

  defp lifecycle_error_reply(reason) do
    %{
      status: "error",
      reason: Atom.to_string(reason),
      message: "Could not update workout lifecycle. Try again.",
      retryable: reason not in [:aborted, :already_reported, :report_conflict]
    }
  end

  defp save_reply({:ok, session, result}) do
    %{
      status: "ok",
      session_id: session.id,
      lifecycle_status: Atom.to_string(session.status),
      report_status: Atom.to_string(result),
      redirect_to: ~p"/stats"
    }
  end

  defp save_reply({:error, %Ecto.Changeset{} = changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
    {global_errors, field_errors} = Map.pop(errors, :base, [])

    %{
      status: "invalid",
      field_errors:
        Map.new(field_errors, fn {field, messages} -> {Atom.to_string(field), messages} end),
      global_errors: global_errors
    }
  end

  defp save_reply({:error, reason}) when reason in [:report_conflict, :aborted, :not_found] do
    %{
      status: "error",
      reason: Atom.to_string(reason),
      message: "Could not save. Try again.",
      retryable: reason == :not_found
    }
  end

  defp save_reply({:error, _reason}) do
    %{status: "error", message: "Could not save. Try again.", retryable: true}
  end

  defp program_summary(%ExecutionProgram{} = program) do
    %{
      burpee_count_total: program.target_reps,
      duration_sec_total: program.target_duration_sec
    }
  end

  defp serialize_program(%ExecutionProgram{} = program) do
    %{
      program_id: program.id,
      program_hash: program.content_hash,
      target_reps: program.target_reps,
      target_duration_sec: program.target_duration_sec,
      events: program_events_for_runner(program.program_json),
      display: map_get(program.summary_json || %{}, :display, %{})
    }
  end

  defp program_events_for_runner(program_json) do
    program_json
    |> map_get(:events, [])
    |> Enum.map(&program_event_for_runner/1)
  end

  defp program_event_for_runner(event) do
    case map_get(event, :kind) do
      "work" ->
        sec_per_rep_us = map_get(event, :sec_per_rep_us)
        sec_per_burpee_us = map_get(event, :sec_per_burpee_us, sec_per_rep_us)

        %{
          kind: "work",
          reps: map_get(event, :reps),
          sec_per_rep: sec_per_rep_us / 1_000_000,
          sec_per_burpee: sec_per_burpee_us / 1_000_000
        }

      "rest" ->
        %{
          kind: "rest",
          duration_sec: map_get(event, :duration_ms) / 1000
        }
    end
  end

  defp program_target_pace_sec(%ExecutionProgram{} = program) do
    {reps_total, sec_total} =
      program.program_json
      |> map_get(:events, [])
      |> Enum.reduce({0, 0.0}, fn event, {reps_total, sec_total} ->
        case map_get(event, :kind) do
          "work" ->
            reps = map_get(event, :reps)
            sec_per_rep = map_get(event, :sec_per_rep_us) / 1_000_000
            {reps_total + reps, sec_total + reps * sec_per_rep}

          _other ->
            {reps_total, sec_total}
        end
      end)

    if reps_total == 0, do: nil, else: Float.round(sec_total / reps_total, 3)
  end

  defp map_get(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp blank_session(plan), do: %WorkoutSession{user_id: plan.user_id, plan_id: plan.id}
end
