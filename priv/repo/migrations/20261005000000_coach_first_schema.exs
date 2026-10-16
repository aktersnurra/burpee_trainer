defmodule BurpeeTrainer.Repo.Migrations.CoachFirstSchema do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Pinned master stowxlvl / 9d8bfcf7 (20 shared migrations, including OIDC).
  # The complete sqlite_master catalog is classified under the write lock.
  @source_fingerprint "8d9e33f9c64ff4feae3dd0fd9a425ca403fc6d9d065159a7a3e576dfa8355a32"
  @target_fingerprint "6bdac2cdb8413a147ba6063779abdcc073648c36c68af9e153b9024c99405242"
  @fallback_definition_json ~S|{"burpee_type":"six_count","events":[{"kind":"work","reps":10,"sec_per_burpee":12.0,"sec_per_rep":12.0}],"name":"Built-in Steady 10","pacing_style":"even","rationale":"A steady reusable fallback that works without provider credentials.","target_duration_sec":120,"target_reps":10,"version":1}|
  @fallback_program_json ~S|{"burpee_type":"six_count","events":[{"duration_sec":120.0,"kind":"work","reps":10,"sec_per_burpee_us":12000000,"sec_per_rep_us":12000000}],"schema_version":3,"semantics":{"definition_hash":"3f3fe32fe29452baa76ea5ba52a3559f1e2e0c84a3c7beb7fe289a67ce271b02","pacing_style":"even"},"solver_version":1,"target_duration_ms":120000,"target_reps":10}|
  @fallback_content_hash "0b39f19b165d83aed946acea3071e3bffacb61861d208bd87f29b327e03a9202"

  @source_tables ~w[execution_programs goals pose_capture_runs pose_trace_chunks style_performances user_stats users workout_plans workout_sessions workout_videos]
  @copied_sources ~w[execution_programs goals pose_capture_runs pose_trace_chunks user_stats users workout_plans workout_sessions workout_videos]

  # Final definitions only: no intermediate authorization/preparation schemas.
  @tables [
    ~S"""
    CREATE TABLE "coach_guidance_entries" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "user_id" INTEGER NOT NULL CONSTRAINT "coach_guidance_entries_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "text" TEXT NOT NULL, "kind" TEXT DEFAULT 'pending' NOT NULL, "summary" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """,
    ~S"""
    CREATE TABLE coach_recommendations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL CONSTRAINT coach_recommendations_user_id_fkey REFERENCES users(id) ON DELETE CASCADE,
      slot_key TEXT NOT NULL,
      slot_date TEXT NOT NULL,
      selected_workout_plan_id INTEGER CONSTRAINT coach_recommendations_selected_workout_plan_id_fkey REFERENCES workout_plans(id) ON DELETE RESTRICT,
      selected_workout_video_id INTEGER CONSTRAINT coach_recommendations_selected_workout_video_id_fkey REFERENCES workout_videos(id) ON DELETE RESTRICT,
      pending_draft_id INTEGER CONSTRAINT coach_recommendations_pending_draft_id_fkey REFERENCES workout_plans(id) ON DELETE SET NULL,
      rationale TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL, "home_workout_plan_id" INTEGER CONSTRAINT "coach_recommendations_home_workout_plan_id_fkey" REFERENCES "workout_plans"("id") ON DELETE SET NULL, "home_revision" INTEGER DEFAULT 0 NOT NULL, "ranked_plan_ids" TEXT DEFAULT ('{}') NOT NULL,
      CONSTRAINT coach_recommendations_selection_check CHECK (
        (selected_workout_plan_id IS NOT NULL AND selected_workout_video_id IS NULL)
        OR (selected_workout_plan_id IS NULL AND selected_workout_video_id IS NOT NULL)
      )
    )
    """,
    ~S"""
    CREATE TABLE "coach_settings" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "user_id" INTEGER NOT NULL CONSTRAINT "coach_settings_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "settings" TEXT DEFAULT ('{}') NOT NULL, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """,
    ~S"""
    CREATE TABLE "coach_workout_memories" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "user_id" INTEGER NOT NULL CONSTRAINT "coach_workout_memories_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "workout_plan_id" INTEGER NOT NULL, "design_session_id" INTEGER, "facts" TEXT NOT NULL, "workout_reason" TEXT NOT NULL, "inserted_at" TEXT NOT NULL)
    """,
    ~S"""
    CREATE TABLE "goals" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "user_id" INTEGER NOT NULL CONSTRAINT "goals_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "burpee_type" TEXT NOT NULL, "burpee_count_target" INTEGER NOT NULL, "duration_sec_target" INTEGER NOT NULL, "date_target" TEXT NOT NULL, "burpee_count_baseline" INTEGER NOT NULL, "duration_sec_baseline" INTEGER NOT NULL, "date_baseline" TEXT NOT NULL, "status" TEXT DEFAULT 'active' NOT NULL, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """,
    ~S"""
    CREATE TABLE "pose_capture_runs" (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL CONSTRAINT pose_capture_runs_user_id_fkey REFERENCES users(id) ON DELETE CASCADE,
      workout_session_id INTEGER CONSTRAINT pose_capture_runs_workout_session_id_fkey REFERENCES workout_sessions(id) ON DELETE SET NULL,
      status TEXT NOT NULL DEFAULT 'active',
      capture_version INTEGER NOT NULL DEFAULT 1,
      started_at TEXT NOT NULL,
      completed_at TEXT,
      aborted_at TEXT,
      abort_reason TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    ~S"""
    CREATE TABLE "pose_trace_chunks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "pose_capture_run_id" INTEGER NOT NULL CONSTRAINT "pose_trace_chunks_pose_capture_run_id_fkey" REFERENCES "pose_capture_runs"("id") ON DELETE CASCADE, "segment" TEXT NOT NULL, "chunk_index" INTEGER NOT NULL, "started_at_ms" INTEGER NOT NULL, "ended_at_ms" INTEGER NOT NULL, "sample_count" INTEGER NOT NULL, "payload_json" TEXT NOT NULL, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "payload_digest" TEXT DEFAULT '' NOT NULL)
    """,
    ~S"""
    CREATE TABLE "user_stats" ("user_id" INTEGER PRIMARY KEY AUTOINCREMENT CONSTRAINT "user_stats_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "previous_best_weeks" INTEGER DEFAULT 0 NOT NULL, "previous_best_ended_on" TEXT, "updated_at" TEXT NOT NULL, "best_week_pushups" INTEGER DEFAULT 0 NOT NULL, "best_week_pushups_on" TEXT, "best_session_pushups" INTEGER DEFAULT 0 NOT NULL, "best_session_pushups_on" TEXT, "best_pace_sec_per_burpee" NUMERIC, "best_pace_on" TEXT, "lifetime_pushup_milestone" INTEGER DEFAULT 0 NOT NULL)
    """,
    ~S"""
    CREATE TABLE "users" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "username" TEXT NOT NULL, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "timezone" TEXT DEFAULT 'Etc/UTC' NOT NULL, "timezone_provisioned" INTEGER DEFAULT false NOT NULL, "oidc_sub" TEXT)
    """,
    ~S"""
    CREATE TABLE "workout_design_entries" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "design_session_id" INTEGER NOT NULL CONSTRAINT "workout_design_entries_design_session_id_fkey" REFERENCES "workout_design_sessions"("id") ON DELETE CASCADE, "attempt_id" TEXT NOT NULL, "kind" TEXT NOT NULL, "payload" TEXT NOT NULL, "inserted_at" TEXT NOT NULL)
    """,
    ~S"""
    CREATE TABLE "workout_design_sessions" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "user_id" INTEGER NOT NULL CONSTRAINT "workout_design_sessions_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "workspace_key" TEXT NOT NULL, "source_plan_id" INTEGER, "inserted_at" TEXT NOT NULL)
    """,
    ~S"""
    CREATE TABLE "workout_plans" (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER CONSTRAINT workout_plans_user_id_fkey REFERENCES users(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      origin TEXT NOT NULL,
      state TEXT NOT NULL,
      request_text TEXT,
      definition_json TEXT NOT NULL,
      program_json TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      burpee_type TEXT NOT NULL,
      target_reps INTEGER,
      target_duration_sec INTEGER,
      published_at TEXT,
      archived_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL, "design_session_id" INTEGER CONSTRAINT "workout_plans_design_session_id_fkey" REFERENCES "workout_design_sessions"("id") ON DELETE SET NULL,
      CONSTRAINT workout_plans_origin_owner_check CHECK (
        (origin = 'built_in' AND user_id IS NULL)
        OR (origin IN ('user','coach') AND user_id IS NOT NULL)
      ),
      CONSTRAINT workout_plans_state_timestamp_check CHECK (
        (state = 'draft' AND published_at IS NULL AND archived_at IS NULL)
        OR (state = 'published' AND published_at IS NOT NULL AND archived_at IS NULL)
        OR (state = 'archived' AND published_at IS NOT NULL AND archived_at IS NOT NULL)
      ),
      CONSTRAINT workout_plans_content_check CHECK (
        TRIM(name) <> ''
        AND json_valid(definition_json) AND json_type(definition_json) = 'object'
        AND json_valid(program_json) AND json_type(program_json) = 'object'
        AND TRIM(content_hash) <> ''
        AND burpee_type IN ('six_count','navy_seal')
        AND (target_reps IS NULL OR target_reps > 0)
        AND (target_duration_sec IS NULL OR target_duration_sec > 0)
      )
    )
    """,
    ~S"""
    CREATE TABLE "workout_sessions" (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL CONSTRAINT workout_sessions_user_id_fkey REFERENCES users(id) ON DELETE CASCADE,
      state TEXT NOT NULL,
      source_kind TEXT NOT NULL,
      plan_id INTEGER CONSTRAINT workout_sessions_plan_id_fkey REFERENCES workout_plans(id) ON DELETE SET NULL,
      goal_id INTEGER CONSTRAINT workout_sessions_goal_id_fkey REFERENCES goals(id) ON DELETE SET NULL,
      workout_video_id INTEGER CONSTRAINT workout_sessions_workout_video_id_fkey REFERENCES workout_videos(id) ON DELETE SET NULL,
      display_name_snapshot TEXT,
      workout_type_snapshot TEXT,
      program_snapshot TEXT,
      video_snapshot TEXT,
      content_hash TEXT,
      client_session_id TEXT,
      started_at TEXT,
      completed_at TEXT,
      burpee_type TEXT NOT NULL,
      burpee_count_planned INTEGER,
      duration_sec_planned INTEGER,
      burpee_count_actual INTEGER,
      duration_sec_actual INTEGER,
      note_pre TEXT,
      note_post TEXT,
      mood INTEGER,
      tags TEXT,
      capture_mode TEXT NOT NULL DEFAULT 'logged',
      cadence_ms TEXT,
      target_pace_sec NUMERIC,
      pace_consistency NUMERIC,
      context_low_energy INTEGER NOT NULL DEFAULT 0,
      context_high_energy INTEGER NOT NULL DEFAULT 0,
      context_heat_affected INTEGER NOT NULL DEFAULT 0,
      primary_limiter TEXT,
      preference_feedback TEXT,
      prescribed_sets_completed INTEGER,
      reps_delta INTEGER,
      shortened INTEGER,
      recovery_delta_sec INTEGER,
      pace_delta_sec NUMERIC,
      cadence_decline NUMERIC,
      style_name TEXT,
      rate_per_min_actual NUMERIC,
      days_since_last INTEGER,
      rate_delta NUMERIC,
      rate_avg_rolling_3 NUMERIC,
      time_of_day_bucket TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT workout_sessions_context_energy_check CHECK (
        COALESCE(context_low_energy, 0) = 0 OR COALESCE(context_high_energy, 0) = 0
      ),
      CONSTRAINT workout_sessions_primary_limiter_check CHECK (
        primary_limiter IS NULL OR primary_limiter IN ('breathing','whole_body','upper_body','legs')
      ),
      CONSTRAINT workout_sessions_preference_feedback_check CHECK (
        preference_feedback IS NULL OR preference_feedback IN ('choose_again','avoid')
      ),
      CONSTRAINT workout_sessions_source_snapshot_check CHECK (
        burpee_type IN ('six_count','navy_seal')
        AND capture_mode IN ('tracked','timed','logged')
        AND (
          state <> 'started'
          OR (
            workout_type_snapshot IS NOT NULL
            AND workout_type_snapshot IN ('six_count','navy_seal')
            AND workout_type_snapshot = burpee_type
          )
        )
        AND (program_snapshot IS NULL OR (json_valid(program_snapshot) AND json_type(program_snapshot) = 'object'))
        AND (video_snapshot IS NULL OR (
          json_valid(video_snapshot)
          AND json_type(video_snapshot) = 'object'
          AND json_type(video_snapshot, '$.name') = 'text'
          AND json_type(video_snapshot, '$.filename') = 'text'
          AND json_extract(video_snapshot, '$.type') IN ('six_count','navy_seal')
          AND json_type(video_snapshot, '$.duration') = 'integer'
          AND json_extract(video_snapshot, '$.duration') > 0
          AND (json_type(video_snapshot, '$.count') = 'null'
            OR (json_type(video_snapshot, '$.count') = 'integer' AND json_extract(video_snapshot, '$.count') > 0))
          AND json_extract(video_snapshot, '$.format') = 'follow_along'
          AND json_remove(video_snapshot, '$.name', '$.filename', '$.type', '$.duration', '$.count', '$.format') = '{}'
        ))
        AND (
          (state = 'started' AND source_kind = 'plan'
            AND plan_id IS NOT NULL AND workout_video_id IS NULL
            AND display_name_snapshot IS NOT NULL
            AND program_snapshot IS NOT NULL AND video_snapshot IS NULL
            AND content_hash IS NOT NULL AND client_session_id IS NOT NULL
            AND started_at IS NOT NULL AND completed_at IS NULL
            AND burpee_count_actual IS NULL AND duration_sec_actual IS NULL)
          OR
          (state = 'started' AND source_kind = 'video'
            AND plan_id IS NULL AND workout_video_id IS NOT NULL
            AND display_name_snapshot IS NOT NULL
            AND workout_type_snapshot = burpee_type
            AND workout_type_snapshot = json_extract(video_snapshot, '$.type')
            AND program_snapshot IS NULL AND video_snapshot IS NOT NULL
            AND content_hash IS NOT NULL AND client_session_id IS NOT NULL
            AND started_at IS NOT NULL AND completed_at IS NULL
            AND burpee_count_actual IS NULL AND duration_sec_actual IS NULL)
          OR
          (state = 'completed' AND source_kind = 'plan'
            AND plan_id IS NOT NULL AND workout_video_id IS NULL
            AND display_name_snapshot IS NOT NULL
            AND program_snapshot IS NOT NULL AND video_snapshot IS NULL
            AND content_hash IS NOT NULL AND client_session_id IS NOT NULL
            AND started_at IS NOT NULL AND completed_at IS NOT NULL
            AND burpee_count_actual IS NOT NULL AND duration_sec_actual IS NOT NULL)
          OR
          (state = 'completed' AND source_kind = 'plan'
            AND plan_id IS NULL AND workout_video_id IS NULL
            AND display_name_snapshot IS NOT NULL AND video_snapshot IS NULL
            AND completed_at IS NOT NULL
            AND burpee_count_actual IS NOT NULL AND duration_sec_actual IS NOT NULL
            AND (program_snapshot IS NULL OR content_hash IS NOT NULL))
          OR
          (state = 'completed' AND source_kind = 'video'
            AND plan_id IS NULL AND program_snapshot IS NULL
            AND display_name_snapshot IS NOT NULL AND video_snapshot IS NOT NULL
            AND workout_type_snapshot IS NOT NULL
            AND workout_type_snapshot IN ('six_count','navy_seal')
            AND workout_type_snapshot = burpee_type
            AND workout_type_snapshot = json_extract(video_snapshot, '$.type')
            AND content_hash IS NOT NULL AND completed_at IS NOT NULL
            AND burpee_count_actual IS NOT NULL AND duration_sec_actual IS NOT NULL)
          OR
          (state = 'completed' AND source_kind = 'manual'
            AND plan_id IS NULL AND workout_video_id IS NULL
            AND program_snapshot IS NULL AND video_snapshot IS NULL
            AND completed_at IS NOT NULL
            AND burpee_count_actual IS NOT NULL AND duration_sec_actual IS NOT NULL)
        )
      )
    )
    """,
    ~S"""
    CREATE TABLE "workout_videos" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "filename" TEXT NOT NULL, "burpee_type" TEXT NOT NULL, "duration_sec" INTEGER NOT NULL, "burpee_count" INTEGER, "inserted_at" TEXT NOT NULL, "available" INTEGER DEFAULT true NOT NULL, "format" TEXT DEFAULT 'follow_along' NOT NULL CONSTRAINT workout_videos_format_check CHECK (format IN ('follow_along')))
    """
  ]

  @objects [
    ~S"""
    CREATE INDEX "coach_guidance_entries_user_id_id_index" ON "coach_guidance_entries" ("user_id", "id")
    """,
    ~S"""
    CREATE INDEX "coach_recommendations_home_workout_plan_id_index" ON "coach_recommendations" ("home_workout_plan_id")
    """,
    ~S"""
    CREATE INDEX coach_recommendations_user_id_slot_date_index ON coach_recommendations (user_id, slot_date)
    """,
    ~S"""
    CREATE UNIQUE INDEX coach_recommendations_user_id_slot_key_index ON coach_recommendations (user_id, slot_key)
    """,
    ~S"""
    CREATE UNIQUE INDEX "coach_settings_user_id_index" ON "coach_settings" ("user_id")
    """,
    ~S"""
    CREATE UNIQUE INDEX "coach_workout_memories_user_id_workout_plan_id_index" ON "coach_workout_memories" ("user_id", "workout_plan_id")
    """,
    ~S"""
    CREATE UNIQUE INDEX "goals_active_user_type_index" ON "goals" ("user_id", "burpee_type") WHERE status = 'active'
    """,
    ~S"""
    CREATE INDEX "goals_user_id_burpee_type_index" ON "goals" ("user_id", "burpee_type")
    """,
    ~S"""
    CREATE INDEX "goals_user_id_index" ON "goals" ("user_id")
    """,
    ~S"""
    CREATE INDEX pose_capture_runs_status_index ON pose_capture_runs (status)
    """,
    ~S"""
    CREATE INDEX pose_capture_runs_user_id_index ON pose_capture_runs (user_id)
    """,
    ~S"""
    CREATE INDEX pose_capture_runs_workout_session_id_index ON pose_capture_runs (workout_session_id)
    """,
    ~S"""
    CREATE UNIQUE INDEX pose_capture_runs_workout_session_id_unique_index ON pose_capture_runs (workout_session_id) WHERE workout_session_id IS NOT NULL
    """,
    ~S"""
    CREATE UNIQUE INDEX "pose_trace_chunks_pose_capture_run_id_chunk_index_index" ON "pose_trace_chunks" ("pose_capture_run_id", "chunk_index")
    """,
    ~S"""
    CREATE INDEX "pose_trace_chunks_pose_capture_run_id_index" ON "pose_trace_chunks" ("pose_capture_run_id")
    """,
    ~S"""
    CREATE INDEX "pose_trace_chunks_pose_capture_run_id_segment_index" ON "pose_trace_chunks" ("pose_capture_run_id", "segment")
    """,
    ~S"""
    CREATE UNIQUE INDEX "users_oidc_sub_index" ON "users" ("oidc_sub")
    """,
    ~S"""
    CREATE UNIQUE INDEX "users_username_index" ON "users" ("username")
    """,
    ~S"""
    CREATE UNIQUE INDEX "workout_design_entries_design_session_id_attempt_id_kind_index" ON "workout_design_entries" ("design_session_id", "attempt_id", "kind")
    """,
    ~S"""
    CREATE INDEX "workout_design_entries_design_session_id_id_index" ON "workout_design_entries" ("design_session_id", "id")
    """,
    ~S"""
    CREATE UNIQUE INDEX "workout_design_sessions_user_id_workspace_key_index" ON "workout_design_sessions" ("user_id", "workspace_key")
    """,
    ~S"""
    CREATE INDEX workout_plans_content_hash_index ON workout_plans (content_hash)
    """,
    ~S"""
    CREATE INDEX workout_plans_state_index ON workout_plans (state)
    """,
    ~S"""
    CREATE INDEX workout_plans_user_id_index ON workout_plans (user_id)
    """,
    ~S"""
    CREATE INDEX workout_sessions_goal_id_index ON workout_sessions (goal_id)
    """,
    ~S"""
    CREATE INDEX workout_sessions_plan_id_index ON workout_sessions (plan_id)
    """,
    ~S"""
    CREATE INDEX workout_sessions_user_id_burpee_type_index ON workout_sessions (user_id, burpee_type)
    """,
    ~S"""
    CREATE UNIQUE INDEX workout_sessions_user_id_client_session_id_index ON workout_sessions (user_id, client_session_id) WHERE client_session_id IS NOT NULL
    """,
    ~S"""
    CREATE INDEX workout_sessions_user_id_index ON workout_sessions (user_id)
    """,
    ~S"""
    CREATE INDEX workout_sessions_user_id_inserted_at_index ON workout_sessions (user_id, inserted_at)
    """,
    ~S"""
    CREATE INDEX workout_sessions_workout_video_id_index ON workout_sessions (workout_video_id)
    """,
    ~S"""
    CREATE UNIQUE INDEX "workout_videos_filename_index" ON "workout_videos" ("filename")
    """,
    ~S"""
    CREATE TRIGGER coach_recommendations_pending_draft_insert_trigger
    BEFORE INSERT ON coach_recommendations
    FOR EACH ROW
    WHEN NEW.pending_draft_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM workout_plans AS draft
       WHERE draft.id = NEW.pending_draft_id
         AND draft.user_id = NEW.user_id
         AND draft.state = 'draft'
     )
    BEGIN
      SELECT RAISE(ABORT, 'coach_recommendations_pending_draft_check');
    END
    """,
    ~S"""
    CREATE TRIGGER coach_recommendations_pending_draft_update_trigger
    BEFORE UPDATE ON coach_recommendations
    FOR EACH ROW
    WHEN NEW.pending_draft_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM workout_plans AS draft
       WHERE draft.id = NEW.pending_draft_id
         AND draft.user_id = NEW.user_id
         AND draft.state = 'draft'
     )
    BEGIN
      SELECT RAISE(ABORT, 'coach_recommendations_pending_draft_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_design_entries_no_update
    BEFORE UPDATE ON workout_design_entries
    BEGIN SELECT RAISE(ABORT, 'design_entries_append_only'); END
    """,
    ~S"""
    CREATE TRIGGER workout_plans_draft_only_delete_trigger
    BEFORE DELETE ON workout_plans
    FOR EACH ROW
    WHEN OLD.state <> 'draft'
    BEGIN
      SELECT RAISE(ABORT, 'workout_plans_draft_only_delete_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_plans_immutable_content_update_trigger
    BEFORE UPDATE ON workout_plans
    FOR EACH ROW
    WHEN OLD.state IN ('published', 'archived')
     AND (
       NEW.user_id IS NOT OLD.user_id
       OR NEW.name IS NOT OLD.name
       OR NEW.origin IS NOT OLD.origin
       OR NEW.request_text IS NOT OLD.request_text
       OR NEW.definition_json IS NOT OLD.definition_json
       OR NEW.program_json IS NOT OLD.program_json
       OR NEW.content_hash IS NOT OLD.content_hash
       OR NEW.burpee_type IS NOT OLD.burpee_type
       OR NEW.target_reps IS NOT OLD.target_reps
       OR NEW.target_duration_sec IS NOT OLD.target_duration_sec
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_plans_immutable_content_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_plans_pending_draft_guard_trigger
    BEFORE UPDATE OF state, user_id ON workout_plans
    FOR EACH ROW
    WHEN EXISTS (
      SELECT 1
      FROM coach_recommendations AS recommendation
      WHERE recommendation.pending_draft_id = OLD.id
        AND (NEW.state <> 'draft' OR NEW.user_id IS NOT recommendation.user_id)
    )
    BEGIN
      SELECT RAISE(ABORT, 'workout_plans_pending_draft_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_plans_state_transition_trigger
    BEFORE UPDATE OF state ON workout_plans
    FOR EACH ROW
    WHEN NOT (
      NEW.state = OLD.state
      OR (OLD.state = 'draft' AND NEW.state = 'published')
      OR (OLD.state = 'published' AND NEW.state = 'archived')
    )
    BEGIN
      SELECT RAISE(ABORT, 'workout_plans_state_transition_check');
    END
    """,
    ~S"""
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
    """,
    ~S"""
    CREATE TRIGGER workout_sessions_identity_snapshot_immutable_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NEW.user_id IS NOT OLD.user_id
      OR NEW.source_kind IS NOT OLD.source_kind
      OR NEW.plan_id IS NOT OLD.plan_id
      OR NOT (
        NEW.workout_video_id IS OLD.workout_video_id
        OR (
          OLD.state = 'completed'
          AND OLD.source_kind = 'video'
          AND OLD.workout_video_id IS NOT NULL
          AND NEW.workout_video_id IS NULL
        )
      )
      OR NEW.display_name_snapshot IS NOT OLD.display_name_snapshot
      OR NEW.workout_type_snapshot IS NOT OLD.workout_type_snapshot
      OR NEW.program_snapshot IS NOT OLD.program_snapshot
      OR NEW.video_snapshot IS NOT OLD.video_snapshot
      OR NEW.content_hash IS NOT OLD.content_hash
      OR NEW.client_session_id IS NOT OLD.client_session_id
      OR NEW.started_at IS NOT OLD.started_at
      OR NEW.burpee_type IS NOT OLD.burpee_type
      OR NEW.burpee_count_planned IS NOT OLD.burpee_count_planned
      OR NEW.duration_sec_planned IS NOT OLD.duration_sec_planned
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_identity_snapshot_immutable_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_sessions_live_plan_snapshot_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NEW.plan_id IS NOT NULL
     AND NEW.display_name_snapshot IS NOT NULL
     AND NEW.workout_type_snapshot IS NOT NULL
     AND NEW.program_snapshot IS NOT NULL
     AND NEW.content_hash IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM workout_plans AS plan
       WHERE plan.id = NEW.plan_id
         AND plan.name IS NEW.display_name_snapshot
         AND plan.burpee_type IS NEW.workout_type_snapshot
         AND plan.burpee_type IS NEW.burpee_type
         AND plan.program_json IS NEW.program_snapshot
         AND plan.content_hash IS NEW.content_hash
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_live_plan_snapshot_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_sessions_live_plan_snapshot_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NEW.plan_id IS NOT NULL
     AND NEW.display_name_snapshot IS NOT NULL
     AND NEW.workout_type_snapshot IS NOT NULL
     AND NEW.program_snapshot IS NOT NULL
     AND NEW.content_hash IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM workout_plans AS plan
       WHERE plan.id = NEW.plan_id
         AND plan.name IS NEW.display_name_snapshot
         AND plan.burpee_type IS NEW.workout_type_snapshot
         AND plan.burpee_type IS NEW.burpee_type
         AND plan.program_json IS NEW.program_snapshot
         AND plan.content_hash IS NEW.content_hash
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_live_plan_snapshot_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_sessions_live_video_snapshot_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NEW.workout_video_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM workout_videos AS video
       WHERE video.id = NEW.workout_video_id
         AND video.burpee_type IS NEW.workout_type_snapshot
         AND NEW.workout_type_snapshot IS NEW.burpee_type
         AND NEW.workout_type_snapshot IS json_extract(NEW.video_snapshot, '$.type')
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_live_video_snapshot_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_sessions_live_video_snapshot_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NEW.workout_video_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM workout_videos AS video
       WHERE video.id = NEW.workout_video_id
         AND video.burpee_type IS NEW.workout_type_snapshot
         AND NEW.workout_type_snapshot IS NEW.burpee_type
         AND NEW.workout_type_snapshot IS json_extract(NEW.video_snapshot, '$.type')
     )
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_live_video_snapshot_check');
    END
    """,
    ~S"""
    CREATE TRIGGER workout_sessions_state_transition_trigger
    BEFORE UPDATE OF state ON workout_sessions
    FOR EACH ROW
    WHEN NOT (NEW.state = OLD.state OR (OLD.state = 'started' AND NEW.state = 'completed'))
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_state_transition_check');
    END
    """
  ]

  @copies [
    ~S"""
    INSERT INTO users (id, username, inserted_at, updated_at, oidc_sub, timezone, timezone_provisioned)
    SELECT s.id,
           s.username,
           s.inserted_at,
           s.updated_at,
           s.oidc_sub,
           'Etc/UTC',
           0
    FROM coach_first_source_users AS s
    """,
    ~S"""
    INSERT INTO goals (id, user_id, burpee_type, burpee_count_target, duration_sec_target, date_target, burpee_count_baseline, duration_sec_baseline, date_baseline, status, inserted_at, updated_at)
    SELECT s.id,
           s.user_id,
           s.burpee_type,
           s.burpee_count_target,
           s.duration_sec_target,
           s.date_target,
           s.burpee_count_baseline,
           s.duration_sec_baseline,
           s.date_baseline,
           s.status,
           s.inserted_at,
           s.updated_at
    FROM coach_first_source_goals AS s
    """,
    ~S"""
    INSERT INTO user_stats (user_id, previous_best_weeks, previous_best_ended_on, updated_at, best_week_pushups, best_week_pushups_on, best_session_pushups, best_session_pushups_on, best_pace_sec_per_burpee, best_pace_on, lifetime_pushup_milestone)
    SELECT s.user_id,
           s.previous_best_weeks,
           s.previous_best_ended_on,
           s.updated_at,
           s.best_week_pushups,
           s.best_week_pushups_on,
           s.best_session_pushups,
           s.best_session_pushups_on,
           s.best_pace_sec_per_burpee,
           s.best_pace_on,
           s.lifetime_pushup_milestone
    FROM coach_first_source_user_stats AS s
    """,
    ~S"""
    INSERT INTO workout_videos (id, name, filename, burpee_type, duration_sec, burpee_count, inserted_at, available, format)
    SELECT s.id,
           s.name,
           s.filename,
           s.burpee_type,
           s.duration_sec,
           s.burpee_count,
           s.inserted_at,
           1,
           'follow_along'
    FROM coach_first_source_workout_videos AS s
    """,
    ~S"""
    INSERT INTO workout_sessions (id, user_id, state, source_kind, plan_id, goal_id, workout_video_id, display_name_snapshot, workout_type_snapshot, program_snapshot, video_snapshot, content_hash, client_session_id, started_at, completed_at, burpee_type, burpee_count_planned, duration_sec_planned, burpee_count_actual, duration_sec_actual, note_pre, note_post, mood, tags, capture_mode, cadence_ms, target_pace_sec, pace_consistency, context_low_energy, context_high_energy, context_heat_affected, primary_limiter, preference_feedback, prescribed_sets_completed, reps_delta, shortened, recovery_delta_sec, pace_delta_sec, cadence_decline, style_name, rate_per_min_actual, days_since_last, rate_delta, rate_avg_rolling_3, time_of_day_bucket, inserted_at, updated_at)
    SELECT ws.id,
           ws.user_id,
           'completed',
           CASE WHEN ws.video_id IS NOT NULL THEN 'video' WHEN ws.plan_id IS NOT NULL OR ws.execution_program_id IS NOT NULL THEN 'plan' ELSE 'manual' END,
           NULL,
           ws.goal_id,
           wv.id,
           CASE WHEN wv.id IS NOT NULL THEN wv.name WHEN wp.id IS NOT NULL THEN wp.name WHEN ep.id IS NOT NULL THEN 'Historical ' || replace(COALESCE(ep.burpee_type,ws.burpee_type),'_',' ') || ' workout' ELSE NULL END,
           COALESCE(wv.burpee_type,wp.burpee_type,ws.burpee_type),
           ep.program_json,
           CASE WHEN wv.id IS NOT NULL THEN json_object('name',wv.name,'filename',wv.filename,'type',wv.burpee_type,'duration',wv.duration_sec,'count',wv.burpee_count,'format','follow_along') ELSE NULL END,
           CASE WHEN ep.id IS NOT NULL THEN ep.content_hash WHEN wv.id IS NOT NULL THEN 'pending-video-hash' ELSE NULL END,
           ws.client_session_id,
           NULL,
           COALESCE(ws.reported_at,ws.inserted_at),
           ws.burpee_type,
           ws.burpee_count_planned,
           ws.duration_sec_planned,
           ws.burpee_count_actual,
           ws.duration_sec_actual,
           ws.note_pre,
           ws.note_post,
           ws.mood,
           ws.tags,
           ws.capture_mode,
           ws.cadence_ms,
           ws.target_pace_sec,
           ws.pace_consistency,
           0,
           0,
           0,
           NULL,
           NULL,
           NULL,
           NULL,
           NULL,
           NULL,
           NULL,
           NULL,
           ws.style_name,
           ws.rate_per_min_actual,
           ws.days_since_last,
           ws.rate_delta,
           ws.rate_avg_rolling_3,
           ws.time_of_day_bucket,
           ws.inserted_at,
           ws.updated_at
    FROM coach_first_source_workout_sessions AS ws
    LEFT JOIN coach_first_source_workout_plans AS wp ON wp.id = ws.plan_id
    LEFT JOIN coach_first_source_execution_programs AS ep ON ep.id = ws.execution_program_id
    LEFT JOIN coach_first_source_workout_videos AS wv ON wv.id = ws.video_id
    WHERE ws.burpee_count_actual IS NOT NULL AND ws.duration_sec_actual IS NOT NULL
    """,
    ~S"""
    INSERT INTO pose_capture_runs (id, user_id, workout_session_id, status, capture_version, started_at, completed_at, aborted_at, abort_reason, inserted_at, updated_at)
    SELECT s.id,
           s.user_id,
           CASE WHEN s.workout_session_id IN (SELECT id FROM workout_sessions) THEN s.workout_session_id ELSE NULL END,
           s.status,
           s.capture_version,
           s.started_at,
           s.completed_at,
           s.aborted_at,
           s.abort_reason,
           s.inserted_at,
           s.updated_at
    FROM coach_first_source_pose_capture_runs AS s
    WHERE s.status = 'completed'
    """,
    ~S"""
    INSERT INTO pose_trace_chunks (id, pose_capture_run_id, segment, chunk_index, started_at_ms, ended_at_ms, sample_count, payload_json, inserted_at, updated_at, payload_digest)
    SELECT s.id,
           s.pose_capture_run_id,
           s.segment,
           s.chunk_index,
           s.started_at_ms,
           s.ended_at_ms,
           s.sample_count,
           s.payload_json,
           s.inserted_at,
           s.updated_at,
           s.payload_digest
    FROM coach_first_source_pose_trace_chunks AS s
    WHERE s.pose_capture_run_id IN (SELECT id FROM coach_first_source_pose_capture_runs WHERE status = 'completed')
    """
  ]

  def up do
    repo().checkout(
      fn ->
        try do
          repo().query!("PRAGMA foreign_keys = OFF")
          assert_pragma_foreign_keys!(0)

          {:ok, :ok} =
            repo().transaction(
              fn ->
                case schema_fingerprint() do
                  @source_fingerprint ->
                    transform()

                  @target_fingerprint ->
                    :ok

                  fingerprint ->
                    raise "unsupported coach-first migration schema; fingerprint=#{fingerprint}"
                end

                validate_target!()
                :ok
              end,
              mode: :immediate,
              timeout: :infinity
            )
        after
          repo().query!("PRAGMA foreign_keys = ON")
          assert_pragma_foreign_keys!(1)
        end
      end,
      timeout: :infinity
    )
  end

  def down do
    raise "irreversible migration: restore the verified pre-migration SQLite backup while the application is quiesced"
  end

  defp transform do
    sequences =
      Map.new(repo().query!("SELECT name, seq FROM sqlite_sequence").rows, fn [name, seq] ->
        {name, seq}
      end)

    Enum.each(@copied_sources, fn table ->
      repo().query!("CREATE TEMP TABLE coach_first_source_#{table} AS SELECT * FROM #{table}")
    end)

    # Foreign keys are disabled on this checked-out connection before BEGIN.
    # Temporary snapshots let final tables use their exact names and definitions.
    Enum.each(@source_tables, &repo().query!("DROP TABLE #{&1}"))
    Enum.each(@tables, fn sql -> repo().query!(String.trim(sql)) end)
    Enum.each(@copies, fn sql -> repo().query!(sql) end)
    Enum.each(@copied_sources, &repo().query!("DROP TABLE temp.coach_first_source_#{&1}"))

    # Unchanged tables keep sequence presence, including deleted-ID high waters.
    for table <- ~w[users goals user_stats workout_videos pose_trace_chunks] do
      case Map.fetch(sequences, table) do
        {:ok, prior} ->
          repo().query!("DELETE FROM sqlite_sequence WHERE name = ?", [table])
          repo().query!("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", [table, prior])

        :error ->
          repo().query!("DELETE FROM sqlite_sequence WHERE name = ?", [table])
      end
    end

    for table <- ~w[workout_plans workout_sessions pose_capture_runs] do
      restore_sequence(table, Map.get(sequences, table))
    end

    backfill_video_hashes!()
    # Upstream has no published-state plans. The old rebuild retains snapshots,
    # not reusable upstream plan rows. Exact-target retry preserves published rows.
    insert_fallback!()
    Enum.each(@objects, fn sql -> repo().query!(String.trim(sql)) end)
  end

  defp validate_target! do
    unless schema_fingerprint() == @target_fingerprint do
      raise "coach-first target schema validation failed; fingerprint=#{schema_fingerprint()}"
    end

    case repo().query!(
           """
           SELECT COUNT(*) FROM workout_plans
           WHERE user_id IS NULL AND name = 'Built-in Steady 10'
             AND origin = 'built_in' AND state = 'published'
             AND definition_json = ? AND program_json = ? AND content_hash = ?
           """,
           [@fallback_definition_json, @fallback_program_json, @fallback_content_hash]
         ).rows do
      [[1]] -> :ok
      rows -> raise "coach-first fallback validation failed: #{inspect(rows)}"
    end

    assert_database_integrity!()
    assert_target_fact_invariants!()
    assert_sequence_invariants!()
    assert_no_foreign_key_violations!()
  end

  defp assert_pragma_foreign_keys!(expected) do
    case repo().query!("PRAGMA foreign_keys").rows do
      [[^expected]] -> :ok
      rows -> raise "expected PRAGMA foreign_keys=#{expected}, got: #{inspect(rows)}"
    end
  end

  defp assert_no_foreign_key_violations! do
    case repo().query!("PRAGMA foreign_key_check").rows do
      [] -> :ok
      rows -> raise "foreign key violations: #{inspect(rows)}"
    end
  end

  defp schema_fingerprint do
    payload =
      repo().query!("""
      SELECT type, name, tbl_name, COALESCE(sql, '')
      FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name, tbl_name
      """).rows
      |> Enum.map_join("\n", fn row ->
        Enum.map_join(row, "\u001F", fn value ->
          value
          |> to_string()
          |> String.replace(~r/\s+/, " ")
          |> String.trim()
        end)
      end)

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp assert_database_integrity! do
    case repo().query!("PRAGMA integrity_check").rows do
      [["ok"]] -> :ok
      rows -> raise "database integrity check failed: #{inspect(rows)}"
    end
  end

  defp assert_target_fact_invariants! do
    assert_query_empty!(
      """
      SELECT recommendation.id
      FROM coach_recommendations AS recommendation
      LEFT JOIN workout_plans AS draft ON draft.id = recommendation.pending_draft_id
      WHERE recommendation.pending_draft_id IS NOT NULL
        AND (draft.id IS NULL OR draft.user_id IS NOT recommendation.user_id OR draft.state <> 'draft')
      """,
      "invalid pending draft facts"
    )

    assert_query_empty!(
      """
      SELECT session.id
      FROM workout_sessions AS session
      LEFT JOIN workout_plans AS plan ON plan.id = session.plan_id
      WHERE session.plan_id IS NOT NULL
        AND (
          plan.id IS NULL
          OR plan.name IS NOT session.display_name_snapshot
          OR plan.burpee_type IS NOT session.workout_type_snapshot
          OR plan.burpee_type IS NOT session.burpee_type
          OR plan.program_json IS NOT session.program_snapshot
          OR plan.content_hash IS NOT session.content_hash
        )
      """,
      "invalid live plan snapshot facts"
    )

    assert_query_empty!(
      """
      SELECT session.id
      FROM workout_sessions AS session
      LEFT JOIN workout_videos AS video ON video.id = session.workout_video_id
      WHERE session.source_kind = 'video'
        AND (
          session.workout_type_snapshot NOT IN ('six_count','navy_seal')
          OR session.workout_type_snapshot IS NOT session.burpee_type
          OR session.workout_type_snapshot IS NOT json_extract(session.video_snapshot, '$.type')
          OR (
            session.workout_video_id IS NOT NULL
            AND (video.id IS NULL OR video.burpee_type IS NOT session.workout_type_snapshot)
          )
        )
      """,
      "invalid live video snapshot facts"
    )

    repo().query!("""
    SELECT id, video_snapshot, content_hash
    FROM workout_sessions
    WHERE video_snapshot IS NOT NULL
    ORDER BY id
    """).rows
    |> Enum.each(fn [id, encoded, stored_hash] ->
      expected_hash =
        encoded
        |> Jason.decode!()
        |> canonical_json()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      unless stored_hash == expected_hash do
        raise "invalid video snapshot hash for workout_session #{id}"
      end
    end)
  end

  defp assert_query_empty!(sql, label) do
    case repo().query!(sql).rows do
      [] -> :ok
      rows -> raise "#{label}: #{inspect(rows)}"
    end
  end

  defp assert_sequence_invariants! do
    Enum.each(
      ~w[workout_plans coach_recommendations workout_sessions pose_capture_runs],
      fn table ->
        [[maximum_id]] = repo().query!("SELECT COALESCE(MAX(id), 0) FROM #{table}").rows

        case repo().query!("SELECT seq FROM sqlite_sequence WHERE name = ?", [table]).rows do
          [] when maximum_id == 0 ->
            :ok

          [[sequence]] when is_integer(sequence) and sequence >= maximum_id ->
            :ok

          rows ->
            raise "invalid sqlite_sequence for #{table}: max=#{maximum_id}, rows=#{inspect(rows)}"
        end
      end
    )
  end

  defp backfill_video_hashes! do
    rows =
      repo().query!("""
      SELECT id, video_snapshot
      FROM workout_sessions
      WHERE video_snapshot IS NOT NULL
      """).rows

    Enum.each(rows, fn [id, encoded] ->
      snapshot = Jason.decode!(encoded)
      hash = :crypto.hash(:sha256, canonical_json(snapshot)) |> Base.encode16(case: :lower)
      repo().query!("UPDATE workout_sessions SET content_hash = ? WHERE id = ?", [hash, id])
    end)
  end

  defp canonical_json(value) when is_map(value) do
    contents =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} ->
        Jason.encode!(key) <> ":" <> canonical_json(item)
      end)

    "{" <> contents <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp insert_fallback! do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    repo().query!(
      """
      INSERT OR IGNORE INTO workout_plans (
        user_id, name, origin, state, request_text, definition_json,
        program_json, content_hash, burpee_type, target_reps,
        target_duration_sec, published_at, archived_at, inserted_at, updated_at
      )
      VALUES (
        NULL, 'Built-in Steady 10', 'built_in', 'published', NULL,
        json(?), json(?), ?, 'six_count', 10, 120, ?, NULL, ?, ?
      )
      """,
      [
        @fallback_definition_json,
        @fallback_program_json,
        @fallback_content_hash,
        now,
        now,
        now
      ]
    )
  end

  defp restore_sequence(table, prior) do
    key = if table == "user_stats", do: "user_id", else: "id"
    [[maximum_id]] = repo().query!("SELECT COALESCE(MAX(#{key}), 0) FROM #{table}").rows
    sequence = max(prior || 0, maximum_id)
    repo().query!("DELETE FROM sqlite_sequence WHERE name = ?", [table])
    repo().query!("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", [table, sequence])
  end
end
