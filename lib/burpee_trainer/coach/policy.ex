defmodule BurpeeTrainer.Coach.Policy do
  @moduledoc "Deterministic authoritative policy for the user's required training slot."

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User

  alias BurpeeTrainer.Coach.{AuthoritativeSession, CatchUpPolicy}

  alias BurpeeTrainer.{Repo, UserTime}
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan, WorkoutSession}

  @weekly_target_sec 4_800
  @standard_duration_sec 1_200
  @catch_up_floor_sec 2_400
  @six_weeks_sec 42 * 24 * 60 * 60
  @type slot :: %{
          slot_key: String.t(),
          slot_date: Date.t(),
          local_date: Date.t(),
          week_start: Date.t(),
          weekly_target_sec: 4_800,
          completed_sec: non_neg_integer(),
          remaining_sec: non_neg_integer(),
          duration_sec: non_neg_integer(),
          burpee_type: :six_count | :navy_seal,
          strategy: :standard | :catch_up,
          exploration_allowed?: boolean(),
          home_state: :week_complete | :done_today | :workout_needed,
          personal_best: map() | nil,
          feedback: map()
        }

  @spec required_slot(User.t(), DateTime.t()) :: {:ok, slot()} | {:error, Error.t()}
  def required_slot(%User{id: user_id} = user, %DateTime{} = now) do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, week_start_utc, week_end_utc} <- UserTime.week_bounds_utc(context) do
      sessions = completed_sessions(user_id, now)

      week_sessions =
        Enum.filter(sessions, fn session ->
          DateTime.compare(session.completed_at, week_start_utc) != :lt and
            DateTime.compare(session.completed_at, week_end_utc) == :lt
        end)

      completed_sec = Enum.reduce(week_sessions, 0, &(&2 + credited_duration(&1)))
      remaining_sec = max(@weekly_target_sec - completed_sec, 0)

      completed_today? =
        Enum.any?(week_sessions, &(local_date(&1, context.timezone) == context.date))

      burpee_type = required_burpee_type(week_sessions)

      weekend_catch_up? =
        Date.day_of_week(context.date) in [6, 7] and remaining_sec >= @catch_up_floor_sec

      duration_sec =
        if weekend_catch_up?, do: remaining_sec, else: min(remaining_sec, @standard_duration_sec)

      strategy = if weekend_catch_up?, do: :catch_up, else: :standard

      home_state =
        cond do
          completed_sec >= @weekly_target_sec -> :week_complete
          completed_today? -> :done_today
          true -> :workout_needed
        end

      {:ok,
       %{
         slot_key: "#{Date.to_iso8601(context.date)}:#{strategy}",
         slot_date: context.date,
         local_date: context.date,
         week_start: context.week_start,
         weekly_target_sec: @weekly_target_sec,
         completed_sec: completed_sec,
         remaining_sec: remaining_sec,
         duration_sec: duration_sec,
         burpee_type: burpee_type,
         strategy: strategy,
         exploration_allowed?: not weekend_catch_up? and exploration_allowed?(sessions),
         home_state: home_state,
         personal_best: personal_best(sessions, burpee_type, now),
         feedback: typed_feedback(sessions)
       }}
    else
      _invalid_timezone -> {:error, Error.new(:invalid_timezone)}
    end
  end

  @doc "Recomputes a slot from all completions persisted on its local calendar day."
  @spec required_slot_for_date(User.t(), Date.t()) :: {:ok, slot()} | {:error, Error.t()}
  def required_slot_for_date(%User{} = user, %Date{} = slot_date) do
    with {:ok, next_midnight} <-
           UserTime.resolve_local(Date.add(slot_date, 1), ~T[00:00:00], user.timezone),
         {:ok, cutoff_utc} <-
           next_midnight
           |> DateTime.add(-1, :second)
           |> DateTime.shift_zone("Etc/UTC") do
      required_slot(user, cutoff_utc)
    else
      _invalid_timezone -> {:error, Error.new(:invalid_timezone)}
    end
  end

  @doc "Verifies one structured candidate against the authoritative slot and snapshot history."
  @spec verify_candidate(User.t(), Date.t(), WorkoutPlan.t()) :: :ok | {:error, Error.t()}
  def verify_candidate(%User{id: user_id} = user, %Date{} = slot_date, %WorkoutPlan{} = candidate) do
    with {:ok, slot} <- required_slot_for_date(user, slot_date),
         true <- candidate.burpee_type == slot.burpee_type,
         true <- candidate.target_duration_sec == slot.duration_sec,
         {:ok, candidate_fingerprint} <- fingerprint_for_plan(candidate) do
      verify_candidate_strategy(
        slot,
        candidate,
        candidate_fingerprint,
        completed_sessions_for_slot(user_id, user, slot_date)
      )
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid_candidate()
    end
  end

  @spec catch_up_ceiling(pos_integer(), pos_integer()) :: non_neg_integer()
  def catch_up_ceiling(personal_best_reps, duration_sec)
      when is_integer(personal_best_reps) and personal_best_reps > 0 and
             duration_sec in [2_400, 3_600, 4_800] do
    factor = %{2_400 => 75, 3_600 => 60, 4_800 => 50} |> Map.fetch!(duration_sec)
    duration_multiplier = div(duration_sec, @standard_duration_sec)
    div(factor * personal_best_reps * duration_multiplier, 100)
  end

  defp completed_sessions_for_slot(user_id, user, slot_date) do
    with {:ok, next_midnight} <-
           UserTime.resolve_local(Date.add(slot_date, 1), ~T[00:00:00], user.timezone),
         {:ok, cutoff_utc} <- DateTime.shift_zone(next_midnight, "Etc/UTC") do
      completed_sessions(user_id, DateTime.add(cutoff_utc, -1, :second))
    else
      _invalid -> []
    end
  end

  defp completed_sessions(user_id, now) do
    Repo.all(
      from(session in WorkoutSession,
        where:
          session.user_id == ^user_id and session.state == :completed and
            not is_nil(session.completed_at) and session.completed_at <= ^now,
        order_by: [desc: session.completed_at, desc: session.id]
      )
    )
    |> Enum.filter(&AuthoritativeSession.authoritative?/1)
  end

  defp credited_duration(%WorkoutSession{tags: "warmup"}), do: 0

  defp credited_duration(%WorkoutSession{duration_sec_actual: duration})
       when is_integer(duration), do: max(duration, 0)

  defp credited_duration(_session), do: 0

  defp required_burpee_type(sessions) do
    seconds =
      Enum.reduce(sessions, %{six_count: 0, navy_seal: 0}, fn session, totals ->
        Map.update!(totals, session.burpee_type, &(&1 + credited_duration(session)))
      end)

    if seconds.six_count <= seconds.navy_seal, do: :six_count, else: :navy_seal
  end

  defp personal_best(sessions, burpee_type, now) do
    lower_bound = DateTime.add(now, -@six_weeks_sec, :second)

    case CatchUpPolicy.rolling_pb(sessions, burpee_type, now) do
      {:ok, %{completed_at: completed_at} = personal_best} ->
        if AuthoritativeSession.within_window?(completed_at, lower_bound, now),
          do: personal_best,
          else: nil

      :none ->
        nil
    end
  end

  defp verify_candidate_strategy(
         %{strategy: :catch_up} = slot,
         candidate,
         _fingerprint,
         _sessions
       ) do
    with %{reps: personal_best_reps}
         when is_integer(personal_best_reps) and personal_best_reps > 0 <-
           slot.personal_best,
         {:ok, %{ceiling_reps: ceiling}} <-
           CatchUpPolicy.prescription(slot.duration_sec, personal_best_reps, %{}),
         true <- candidate.target_reps <= ceiling do
      :ok
    else
      _invalid -> invalid_candidate()
    end
  end

  defp verify_candidate_strategy(slot, _candidate, candidate_fingerprint, sessions) do
    case latest_structured_fingerprint(sessions) do
      nil ->
        :ok

      reference ->
        case changed_dimensions(reference, candidate_fingerprint) do
          [] -> :ok
          [_one] when slot.exploration_allowed? -> :ok
          _invalid -> invalid_candidate()
        end
    end
  end

  defp latest_structured_fingerprint(sessions) do
    Enum.find_value(sessions, fn session ->
      case fingerprint_for_session(session) do
        {:ok, %{video_format: :program} = fingerprint} -> fingerprint
        _unstructured -> nil
      end
    end)
  end

  defp invalid_candidate do
    {:error, Error.new(:invalid_recommendation_selection, %{reason: :policy_mismatch})}
  end

  defp exploration_allowed?(sessions) do
    recent_ids = sessions |> Enum.take(3) |> MapSet.new(& &1.id)

    sessions
    |> Enum.reduce([], fn session, fingerprints ->
      case fingerprint_for_session(session) do
        {:ok, %{video_format: :program} = fingerprint} ->
          [{session.id, fingerprint} | fingerprints]

        _unstructured ->
          fingerprints
      end
    end)
    |> Enum.reverse()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [{newer_id, newer}, {_older_id, older}] ->
      not (MapSet.member?(recent_ids, newer_id) and
             length(changed_dimensions(older, newer)) == 1)
    end)
  end

  defp fingerprint_for_session(
         %WorkoutSession{source_kind: :plan, program_snapshot: snapshot} = session
       )
       when is_map(snapshot),
       do: program_fingerprint(snapshot, session.burpee_type)

  defp fingerprint_for_session(
         %WorkoutSession{source_kind: :video, video_snapshot: snapshot} = session
       )
       when is_map(snapshot),
       do: video_fingerprint(snapshot, session.burpee_type)

  defp fingerprint_for_session(%WorkoutSession{}), do: :unfingerprintable

  defp fingerprint_for_plan(%WorkoutPlan{program_json: snapshot, burpee_type: burpee_type})
       when is_map(snapshot),
       do: program_fingerprint(snapshot, burpee_type)

  defp fingerprint_for_plan(%WorkoutPlan{}), do: :unfingerprintable

  defp changed_dimensions(left, right) do
    Enum.filter(
      [:burpee_type, :set_shape, :recovery_pattern, :pacing_style, :video_format],
      &(Map.get(left, &1) != Map.get(right, &1))
    )
  end

  defp program_fingerprint(snapshot, fallback_type) do
    with {:ok, burpee_type} <- snapshot_burpee_type(snapshot_value(snapshot, :burpee_type)),
         {:ok, ^burpee_type} <- snapshot_burpee_type(fallback_type),
         events when is_list(events) <- snapshot_value(snapshot, :events),
         true <- events != [] and Enum.all?(events, &valid_snapshot_event?/1),
         {:ok, pacing_style} <- snapshot_pacing_style(snapshot) do
      work_events = Enum.filter(events, &(snapshot_value(&1, :kind) in [:work, "work"]))

      if work_events == [] do
        :unfingerprintable
      else
        {:ok,
         %{
           burpee_type: burpee_type,
           set_shape: snapshot_set_shape(work_events),
           recovery_pattern: snapshot_recovery_pattern(events),
           pacing_style: pacing_style,
           video_format: :program
         }}
      end
    else
      _invalid -> :unfingerprintable
    end
  end

  defp video_fingerprint(snapshot, fallback_type) do
    with {:ok, burpee_type} <- snapshot_burpee_type(snapshot_value(snapshot, :type)),
         {:ok, ^burpee_type} <- snapshot_burpee_type(fallback_type),
         format when format in [:follow_along, "follow_along"] <-
           snapshot_value(snapshot, :format) do
      {:ok,
       %{
         burpee_type: burpee_type,
         set_shape: :none,
         recovery_pattern: :none,
         pacing_style: :none,
         video_format: :follow_along
       }}
    else
      _invalid -> :unfingerprintable
    end
  end

  defp valid_snapshot_event?(event) when is_map(event) do
    case snapshot_value(event, :kind) do
      kind when kind in [:work, "work"] ->
        positive_integer?(snapshot_value(event, :reps)) and
          positive_integer?(snapshot_value(event, :sec_per_rep_us)) and
          positive_integer?(snapshot_value(event, :sec_per_burpee_us))

      kind when kind in [:rest, "rest"] ->
        positive_integer?(snapshot_value(event, :duration_ms))

      _invalid ->
        false
    end
  end

  defp valid_snapshot_event?(_event), do: false

  defp snapshot_set_shape([event]), do: {:single, snapshot_value(event, :reps)}

  defp snapshot_set_shape(events) do
    reps = Enum.map(events, &snapshot_value(&1, :reps))
    if Enum.uniq(reps) |> length() == 1, do: {:uniform, hd(reps)}, else: {:sequence, reps}
  end

  defp snapshot_recovery_pattern(events) do
    windows =
      events
      |> Enum.reduce([], fn event, acc ->
        case {snapshot_value(event, :kind), acc} do
          {kind, _acc} when kind in [:work, "work"] ->
            [0 | acc]

          {kind, [current | rest]} when kind in [:rest, "rest"] ->
            [current + div(snapshot_value(event, :duration_ms), 1_000) | rest]

          _other ->
            acc
        end
      end)
      |> Enum.reverse()

    cond do
      windows == [] or Enum.all?(windows, &(&1 == 0)) -> :none
      Enum.uniq(windows) |> length() == 1 -> {:uniform, hd(windows)}
      true -> {:sequence, windows}
    end
  end

  defp snapshot_pacing_style(snapshot) do
    case snapshot |> snapshot_value(:semantics, %{}) |> snapshot_value(:pacing_style) do
      value when value in [:even, "even"] -> {:ok, :even}
      value when value in [:unbroken, "unbroken"] -> {:ok, :unbroken}
      _invalid -> :error
    end
  end

  defp snapshot_burpee_type(value) when value in [:six_count, "six_count"],
    do: {:ok, :six_count}

  defp snapshot_burpee_type(value) when value in [:navy_seal, "navy_seal"],
    do: {:ok, :navy_seal}

  defp snapshot_burpee_type(_value), do: :error

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp snapshot_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp typed_feedback(sessions) do
    recent = Enum.take(sessions, 3)

    transient =
      recent
      |> Enum.flat_map(fn session ->
        []
        |> maybe_add(session.context_low_energy, :low_energy)
        |> maybe_add(session.context_high_energy, :high_energy)
        |> maybe_add(session.context_heat_affected, :heat_affected_performance)
      end)
      |> Enum.uniq()

    %{
      transient: transient,
      limiters:
        recent
        |> Enum.map(& &1.primary_limiter)
        |> Enum.filter(&(&1 in [:breathing, :whole_body, :upper_body, :legs]))
        |> Enum.uniq(),
      preferences:
        recent
        |> Enum.map(& &1.preference_feedback)
        |> Enum.filter(&(&1 in [:choose_again, :avoid]))
        |> Enum.uniq()
    }
  end

  defp maybe_add(values, true, value), do: [value | values]
  defp maybe_add(values, _false, _value), do: values

  defp local_date(session, timezone) do
    case UserTime.local_date(session.completed_at, timezone) do
      {:ok, date} -> date
      _invalid -> nil
    end
  end
end
