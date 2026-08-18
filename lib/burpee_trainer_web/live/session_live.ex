defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc "Loads and completes one immutable started workout-session snapshot."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.{CoreComponents, SessionComponents}

  @completion_integer_fields ~w[
    burpee_count_actual
    burpee_count_planned
    duration_sec_actual
    duration_sec_planned
  ]
  @completion_text_fields ~w[note_pre note_post]
  @completion_tags ~w[tired great_energy bad_sleep sick travel hot]
  @completion_boolean_fields ~w[
    context_low_energy
    context_high_energy
    context_heat_affected
  ]
  @completion_enum_fields %{
    "burpee_type" => ~w[six_count navy_seal],
    "primary_limiter" => ~w[breathing whole_body upper_body legs],
    "preference_feedback" => ~w[choose_again avoid]
  }

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, id} <- parse_positive_id(session_id),
         {:ok, %WorkoutSession{source_kind: :plan} = workout_session} <-
           Workouts.resume_session(user, id) do
      {:ok, mount_session(socket, workout_session)}
    else
      _unavailable -> unavailable_session(socket)
    end
  end

  defp mount_session(socket, session) do
    program = session.program_snapshot

    socket
    |> assign(:workout_session, session)
    |> assign(:serialized_program, serialize_program(session, program))
    |> assign(:target_pace_sec, program_target_pace_sec(program))
    |> assign(:summary, %{
      burpee_count_total: session.burpee_count_planned,
      duration_sec_total: session.duration_sec_planned
    })
    |> assign(:completion_form, to_form(Ecto.Changeset.change(session)))
  end

  defp unavailable_session(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Session not found.")
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_event(
        "save_session",
        %{"workout_session" => attrs, "tracking" => tracking},
        socket
      )
      when is_map(attrs) and is_map(tracking) do
    with :ok <- validate_completion_attrs(attrs),
         :ok <- validate_tracking(tracking) do
      result =
        Workouts.complete_session(
          socket.assigns.current_user,
          socket.assigns.workout_session.id,
          attrs,
          persistence_mode(attrs, tracking, socket.assigns.target_pace_sec)
        )

      {:reply, save_reply(result), socket}
    else
      {:error, {:field, field}} ->
        {:reply,
         %{
           status: "invalid",
           field_errors: %{field => ["is invalid"]},
           global_errors: []
         }, socket}

      {:error, :invalid_tracking} ->
        {:reply,
         %{
           status: "invalid",
           field_errors: %{},
           global_errors: ["Completion capture data is invalid."]
         }, socket}
    end
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
      current_scope={assigns[:current_scope]}
      navigation?={false}
      flash?={false}
    >
      <div
        id="burpee-session"
        phx-hook="SessionHook"
        phx-update="ignore"
        data-session-program={Jason.encode!(@serialized_program)}
        data-session-id={@workout_session.id}
        data-source-kind={@workout_session.source_kind}
        data-content-hash={@workout_session.content_hash}
        data-client-session-id={@workout_session.client_session_id}
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

  defp parse_positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_id}
    end
  end

  defp parse_positive_id(_forged), do: {:error, :invalid_id}

  defp validate_completion_attrs(attrs) do
    validators =
      Enum.map(@completion_integer_fields, fn field ->
        {field, fn value -> nonnegative_integer?(value) end}
      end) ++
        Enum.map(@completion_text_fields, fn field -> {field, &is_binary/1} end) ++
        Enum.map(@completion_boolean_fields, fn field -> {field, &html_boolean?/1} end) ++
        [
          {"mood", &mood?/1},
          {"tags", &tags?/1},
          {"client_session_id", &uuid?/1}
        ] ++
        Enum.map(@completion_enum_fields, fn {field, values} ->
          {field, fn value -> value in [nil, ""] or (is_binary(value) and value in values) end}
        end)

    Enum.reduce_while(validators, :ok, fn {field, valid?}, :ok ->
      if Map.has_key?(attrs, field) and not valid?.(Map.get(attrs, field)) do
        {:halt, {:error, {:field, field}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_tracking(tracking) do
    valid? =
      is_boolean(tracking["enabled"]) and
        tracking["trust"] in ~w[disabled degraded finished] and
        optional_binary?(tracking["reason"]) and
        optional_nonnegative_integer?(tracking["detected_reps"]) and
        optional_nonnegative_number?(tracking["detected_duration_sec"]) and
        valid_cadence?(tracking["cadence_ms"])

    if valid?, do: :ok, else: {:error, :invalid_tracking}
  end

  defp nonnegative_integer?(value) when is_integer(value), do: value >= 0

  defp nonnegative_integer?(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed >= 0
      _invalid -> false
    end
  end

  defp nonnegative_integer?(_value), do: false
  defp optional_nonnegative_integer?(nil), do: true
  defp optional_nonnegative_integer?(value), do: nonnegative_integer?(value)

  defp optional_nonnegative_number?(nil), do: true
  defp optional_nonnegative_number?(value) when is_number(value), do: value >= 0

  defp optional_nonnegative_number?(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed >= 0
      _invalid -> false
    end
  end

  defp optional_nonnegative_number?(_value), do: false
  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value)
  defp html_boolean?(value), do: is_boolean(value) or value in ["true", "false"]

  defp mood?(value) when value in [-1, 0, 1], do: true

  defp mood?(value) when is_binary(value) do
    case Integer.parse(value) do
      {mood, ""} -> mood in [-1, 0, 1]
      _invalid -> false
    end
  end

  defp mood?(_value), do: false

  defp tags?(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.all?(&(&1 in @completion_tags))
  end

  defp tags?(_value), do: false
  defp uuid?(value) when is_binary(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  defp valid_cadence?(value) when is_list(value) do
    Enum.all?(value, &(is_integer(&1) and &1 >= 0))
  end

  defp valid_cadence?(_value), do: false

  defp persistence_mode(attrs, tracking, target_pace_sec) do
    enabled? = tracking["enabled"] == true
    trust = tracking["trust"]

    cond do
      not enabled? ->
        :timed

      trust == "degraded" ->
        :timed

      trust == "finished" and detected_result_unchanged?(attrs, tracking) ->
        cadence = if is_list(tracking["cadence_ms"]), do: tracking["cadence_ms"], else: []
        {:trusted, cadence, target_pace_sec}

      trust == "finished" ->
        :manual_correction

      true ->
        :timed
    end
  end

  defp detected_result_unchanged?(attrs, tracking) do
    with {:ok, actual_reps} <- parse_integer(attrs["burpee_count_actual"]),
         {:ok, actual_duration} <- parse_number(attrs["duration_sec_actual"]),
         {:ok, detected_reps} <- parse_integer(tracking["detected_reps"]),
         {:ok, detected_duration} <- parse_number(tracking["detected_duration_sec"]) do
      actual_reps == detected_reps and actual_duration == detected_duration
    else
      _ -> false
    end
  end

  defp parse_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_number(value) when is_number(value) and value >= 0, do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_number(_value), do: :error

  defp save_reply({:ok, session}) do
    %{status: "ok", session_id: session.id, redirect_to: ~p"/stats"}
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

  defp save_reply({:error, _reason}) do
    %{status: "error", message: "Could not save. Try again.", retryable: true}
  end

  defp serialize_program(session, program) do
    %{
      program_hash: session.content_hash,
      target_reps: session.burpee_count_planned,
      target_duration_sec: session.duration_sec_planned,
      events: program_events_for_runner(program),
      display: map_get(program, :display, %{})
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
          sec_per_burpee: sec_per_burpee_us / 1_000_000,
          duration_sec: map_get(event, :duration_sec)
        }

      "rest" ->
        %{kind: "rest", duration_sec: map_get(event, :duration_ms) / 1000}
    end
  end

  defp program_target_pace_sec(program) do
    {reps_total, sec_total} =
      program
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
end
