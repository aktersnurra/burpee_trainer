defmodule BurpeeTrainer.Repo.Migrations.SessionFeedbackIsCorrectable do
  @moduledoc """
  A completed session stays the app's permanent record, except the athlete's own
  feedback: notes, tags, mood, limiter, preference, and the energy and heat flags can be
  corrected afterwards (and `updated_at` moves with them). Reps, time, date, the source
  and its snapshot stay locked.
  """
  use Ecto.Migration

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
       AND NEW.pace_consistency IS OLD.pace_consistency
       AND NEW.prescribed_sets_completed IS OLD.prescribed_sets_completed
       AND NEW.reps_delta IS OLD.reps_delta
       AND NEW.shortened IS OLD.shortened
       AND NEW.recovery_delta_sec IS OLD.recovery_delta_sec
       AND NEW.pace_delta_sec IS OLD.pace_delta_sec
       AND NEW.cadence_decline IS OLD.cadence_decline
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
       AND NEW.note_pre IS OLD.note_pre
       AND NEW.note_post IS OLD.note_post
       AND NEW.mood IS OLD.mood
       AND NEW.tags IS OLD.tags
       AND NEW.capture_mode IS OLD.capture_mode
       AND NEW.cadence_ms IS OLD.cadence_ms
       AND NEW.target_pace_sec IS OLD.target_pace_sec
       AND NEW.pace_consistency IS OLD.pace_consistency
       AND NEW.context_low_energy IS OLD.context_low_energy
       AND NEW.context_high_energy IS OLD.context_high_energy
       AND NEW.context_heat_affected IS OLD.context_heat_affected
       AND NEW.primary_limiter IS OLD.primary_limiter
       AND NEW.preference_feedback IS OLD.preference_feedback
       AND NEW.prescribed_sets_completed IS OLD.prescribed_sets_completed
       AND NEW.reps_delta IS OLD.reps_delta
       AND NEW.shortened IS OLD.shortened
       AND NEW.recovery_delta_sec IS OLD.recovery_delta_sec
       AND NEW.pace_delta_sec IS OLD.pace_delta_sec
       AND NEW.cadence_decline IS OLD.cadence_decline
       AND NEW.style_name IS OLD.style_name
       AND NEW.rate_per_min_actual IS OLD.rate_per_min_actual
       AND NEW.days_since_last IS OLD.days_since_last
       AND NEW.rate_delta IS OLD.rate_delta
       AND NEW.rate_avg_rolling_3 IS OLD.rate_avg_rolling_3
       AND NEW.time_of_day_bucket IS OLD.time_of_day_bucket
       AND NEW.inserted_at IS OLD.inserted_at
       AND NEW.updated_at IS OLD.updated_at
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_exact_once_completion_check');
    END
    """)
  end
end
