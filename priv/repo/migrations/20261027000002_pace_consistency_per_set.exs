defmodule BurpeeTrainer.Repo.Migrations.PaceConsistencyPerSet do
  @moduledoc """
  Pace consistency was 1 minus the coefficient of variation of every gap between reps,
  rests included, so any workout with rests scored 0. It is now derived with the session's
  fatigue (`Workouts.Fatigue`), from the gaps inside each set against that set's planned
  pace. Like the fatigue columns it is derived from the locked `cadence_ms` and
  `program_snapshot`, so the completion trigger stops locking it, and completed camera
  sessions get it recomputed. Sessions without a camera keep none.
  """
  use Ecto.Migration

  alias BurpeeTrainer.Workouts.Fatigue

  def up do
    execute("DROP TRIGGER workout_sessions_exact_once_completion_trigger")

    execute(~S"""
    CREATE TRIGGER workout_sessions_exact_once_completion_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN OLD.state = 'completed'
     AND NEW.state IS OLD.state
     AND NOT (
       NEW.id IS OLD.id
       AND NEW.user_id IS OLD.user_id
       AND NEW.state IS OLD.state
       AND NEW.source_kind IS OLD.source_kind
       AND NEW.plan_id IS OLD.plan_id
       AND NEW.goal_id IS OLD.goal_id
       AND (
         NEW.workout_video_id IS OLD.workout_video_id
         OR (
           OLD.source_kind = 'video'
           AND OLD.workout_video_id IS NOT NULL
           AND NEW.workout_video_id IS NULL
         )
       )
       AND NEW.display_name_snapshot IS OLD.display_name_snapshot
       AND NEW.workout_type_snapshot IS OLD.workout_type_snapshot
       AND NEW.program_snapshot IS OLD.program_snapshot
       AND NEW.video_snapshot IS OLD.video_snapshot
       AND NEW.content_hash IS OLD.content_hash
       AND NEW.client_session_id IS OLD.client_session_id
       AND NEW.started_at IS OLD.started_at
       AND NEW.completed_at IS OLD.completed_at
       AND NEW.burpee_type IS OLD.burpee_type
       AND NEW.burpee_count_planned IS OLD.burpee_count_planned
       AND NEW.duration_sec_planned IS OLD.duration_sec_planned
       AND NEW.burpee_count_actual IS OLD.burpee_count_actual
       AND NEW.duration_sec_actual IS OLD.duration_sec_actual
       AND NEW.capture_mode IS OLD.capture_mode
       AND NEW.cadence_ms IS OLD.cadence_ms
       AND NEW.target_pace_sec IS OLD.target_pace_sec
       AND NEW.prescribed_sets_completed IS OLD.prescribed_sets_completed
       AND NEW.reps_delta IS OLD.reps_delta
       AND NEW.shortened IS OLD.shortened
       AND NEW.style_name IS OLD.style_name
       AND NEW.rate_per_min_actual IS OLD.rate_per_min_actual
       AND NEW.days_since_last IS OLD.days_since_last
       AND NEW.rate_delta IS OLD.rate_delta
       AND NEW.rate_avg_rolling_3 IS OLD.rate_avg_rolling_3
       AND NEW.time_of_day_bucket IS OLD.time_of_day_bucket
       AND NEW.inserted_at IS OLD.inserted_at
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_exact_once_completion_check');
    END
    """)

    flush()

    %{rows: rows} =
      repo().query!("""
      SELECT id, cadence_ms, program_snapshot FROM workout_sessions
      WHERE state = 'completed' AND cadence_ms IS NOT NULL AND program_snapshot IS NOT NULL
      """)

    for [id, cadence, snapshot] <- rows,
        {:ok, program} <- [Jason.decode(snapshot)] do
      fatigue = Fatigue.for_session(cadence, program)

      repo().query!(
        """
        UPDATE workout_sessions
        SET recovery_delta_sec = ?1, pace_delta_sec = ?2, fatigue_coverage = ?3,
            fatigue_decline = ?4, slip_at_sec = ?5, kept_up = ?6, pace_consistency = ?7
        WHERE id = ?8
        """,
        [
          fatigue.recovery_delta_sec,
          fatigue.pace_delta_sec,
          fatigue.coverage,
          fatigue.decline,
          fatigue.slip_at_sec,
          sqlite_boolean(fatigue.kept_up),
          fatigue.consistency,
          id
        ]
      )
    end
  end

  def down do
    execute("DROP TRIGGER workout_sessions_exact_once_completion_trigger")

    execute(~S"""
    CREATE TRIGGER workout_sessions_exact_once_completion_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN OLD.state = 'completed'
     AND NEW.state IS OLD.state
     AND NOT (
       NEW.id IS OLD.id
       AND NEW.user_id IS OLD.user_id
       AND NEW.state IS OLD.state
       AND NEW.source_kind IS OLD.source_kind
       AND NEW.plan_id IS OLD.plan_id
       AND NEW.goal_id IS OLD.goal_id
       AND (
         NEW.workout_video_id IS OLD.workout_video_id
         OR (
           OLD.source_kind = 'video'
           AND OLD.workout_video_id IS NOT NULL
           AND NEW.workout_video_id IS NULL
         )
       )
       AND NEW.display_name_snapshot IS OLD.display_name_snapshot
       AND NEW.workout_type_snapshot IS OLD.workout_type_snapshot
       AND NEW.program_snapshot IS OLD.program_snapshot
       AND NEW.video_snapshot IS OLD.video_snapshot
       AND NEW.content_hash IS OLD.content_hash
       AND NEW.client_session_id IS OLD.client_session_id
       AND NEW.started_at IS OLD.started_at
       AND NEW.completed_at IS OLD.completed_at
       AND NEW.burpee_type IS OLD.burpee_type
       AND NEW.burpee_count_planned IS OLD.burpee_count_planned
       AND NEW.duration_sec_planned IS OLD.duration_sec_planned
       AND NEW.burpee_count_actual IS OLD.burpee_count_actual
       AND NEW.duration_sec_actual IS OLD.duration_sec_actual
       AND NEW.capture_mode IS OLD.capture_mode
       AND NEW.cadence_ms IS OLD.cadence_ms
       AND NEW.target_pace_sec IS OLD.target_pace_sec
       AND NEW.pace_consistency IS OLD.pace_consistency
       AND NEW.prescribed_sets_completed IS OLD.prescribed_sets_completed
       AND NEW.reps_delta IS OLD.reps_delta
       AND NEW.shortened IS OLD.shortened
       AND NEW.style_name IS OLD.style_name
       AND NEW.rate_per_min_actual IS OLD.rate_per_min_actual
       AND NEW.days_since_last IS OLD.days_since_last
       AND NEW.rate_delta IS OLD.rate_delta
       AND NEW.rate_avg_rolling_3 IS OLD.rate_avg_rolling_3
       AND NEW.time_of_day_bucket IS OLD.time_of_day_bucket
       AND NEW.inserted_at IS OLD.inserted_at
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_exact_once_completion_check');
    END
    """)
  end

  # Raw queries bind booleans as text; Ecto reads SQLite booleans as 0 and 1.
  defp sqlite_boolean(nil), do: nil
  defp sqlite_boolean(value), do: if(value, do: 1, else: 0)
end
