defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc """
  Bootstraps the immutable workout program and renders the stable DOM owned by
  the client session runtime.
  """

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{ExecutionProgram, WorkoutSession}
  alias BurpeeTrainerWeb.SessionComponents

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

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
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
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
