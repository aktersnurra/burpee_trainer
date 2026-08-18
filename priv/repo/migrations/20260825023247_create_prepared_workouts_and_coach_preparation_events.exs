defmodule BurpeeTrainer.Repo.Migrations.CreatePreparedWorkoutsAndCoachPreparationEvents do
  use Ecto.Migration

  @prepared_workouts_lifecycle_check "lifecycle IN ('ready','started','completed','superseded','override_preview')"
  @prepared_workouts_selection_union_check """
  (
    (lifecycle = 'override_preview' AND selection_kind = 'created'
      AND workout_plan_id IS NULL
      AND execution_program_id IS NULL
      AND execution_program_hash IS NULL
      AND workout_video_id IS NULL
      AND candidate_source_json IS NOT NULL
      AND candidate_compile_policy_json IS NOT NULL
      AND candidate_compile_policy_hash IS NOT NULL
      AND candidate_program_json IS NOT NULL
      AND candidate_program_hash IS NOT NULL)
    OR
    ((selection_kind = 'existing_workout'
       OR (selection_kind = 'created' AND lifecycle <> 'override_preview'))
      AND workout_plan_id IS NOT NULL
      AND execution_program_id IS NOT NULL
      AND execution_program_hash IS NOT NULL
      AND workout_video_id IS NULL
      AND candidate_source_json IS NULL
      AND candidate_compile_policy_json IS NULL
      AND candidate_compile_policy_hash IS NULL
      AND candidate_program_json IS NULL
      AND candidate_program_hash IS NULL)
    OR
    (selection_kind = 'video'
      AND workout_video_id IS NOT NULL
      AND workout_plan_id IS NULL
      AND execution_program_id IS NULL
      AND execution_program_hash IS NULL
      AND candidate_source_json IS NULL
      AND candidate_compile_policy_json IS NULL
      AND candidate_compile_policy_hash IS NULL
      AND candidate_program_json IS NULL
      AND candidate_program_hash IS NULL)
  )
  """
  @prepared_workouts_fallback_facts_json_check """
  (
    fallback_facts_json IS NULL
    OR (
      json_valid(fallback_facts_json)
      AND json_type(fallback_facts_json) = 'object'
      AND json_type(fallback_facts_json, '$.selected_burpee_type') = 'text'
      AND json_type(fallback_facts_json, '$.selected_type_source') = 'text'
      AND json_type(fallback_facts_json, '$.capacity_reps') = 'integer'
      AND (json_type(fallback_facts_json, '$.capacity_provenance') = 'text'
        OR json_type(fallback_facts_json, '$.capacity_provenance') = 'null')
      AND (json_type(fallback_facts_json, '$.pb_session_id') = 'integer'
        OR json_type(fallback_facts_json, '$.pb_session_id') = 'null')
      AND (json_type(fallback_facts_json, '$.pb_reps') = 'integer'
        OR json_type(fallback_facts_json, '$.pb_reps') = 'null')
      AND json_type(fallback_facts_json, '$.remaining_sec') = 'integer'
      AND json_type(fallback_facts_json, '$.duration_min') = 'integer'
      AND (json_type(fallback_facts_json, '$.factor_num') = 'integer'
        OR json_type(fallback_facts_json, '$.factor_num') = 'null')
      AND json_type(fallback_facts_json, '$.ceiling_reps') = 'integer'
      AND json_type(fallback_facts_json, '$.suitable_plan_order') = 'array'
      AND json_remove(
        fallback_facts_json,
        '$.selected_burpee_type',
        '$.selected_type_source',
        '$.capacity_reps',
        '$.capacity_provenance',
        '$.pb_session_id',
        '$.pb_reps',
        '$.remaining_sec',
        '$.duration_min',
        '$.factor_num',
        '$.ceiling_reps',
        '$.suitable_plan_order'
      ) = '{}'
    )
  )
  """
  @coach_preparation_events_state_check "state IN ('pending','claimed','fallback_persisted','improving','retryable','completed','failed')"
  @coach_preparation_events_state_lease_check """
  (
    (state IN ('claimed','improving')
      AND TRIM(COALESCE(lease_owner, '')) <> ''
      AND lease_expires_at IS NOT NULL)
    OR
    (state NOT IN ('claimed','improving')
      AND lease_owner IS NULL
      AND lease_expires_at IS NULL)
  )
  """
  @coach_preparation_events_fallback_binding_check """
  (
    (state IN ('fallback_persisted','improving','retryable','completed')
      AND fallback_prepared_workout_id IS NOT NULL)
    OR
    (state IN ('pending','claimed','failed')
      AND fallback_prepared_workout_id IS NULL)
  )
  """
  @coach_preparation_events_retryable_check """
  (
    (state = 'retryable'
      AND next_attempt_at IS NOT NULL
      AND TRIM(COALESCE(last_error, '')) <> '')
    OR
    (state = 'failed'
      AND next_attempt_at IS NULL
      AND TRIM(COALESCE(last_error, '')) <> '')
    OR
    (state NOT IN ('retryable','failed')
      AND next_attempt_at IS NULL
      AND last_error IS NULL)
  )
  """
  @coach_preparation_events_completion_timestamp_check """
  (
    (state = 'completed' AND completed_at IS NOT NULL)
    OR
    (state <> 'completed' AND completed_at IS NULL)
  )
  """
  @coach_preparation_events_completion_outcome_check """
  (
    (state = 'completed'
      AND completion_outcome IS NOT NULL
      AND completion_outcome IN ('improved','fallback'))
    OR
    (state <> 'completed' AND completion_outcome IS NULL)
  )
  """
  @coach_preparation_events_failed_check """
  (
    (state = 'failed'
      AND failed_at IS NOT NULL
      AND fallback_prepared_workout_id IS NULL
      AND completed_at IS NULL
      AND completion_outcome IS NULL
      AND lease_owner IS NULL
      AND lease_expires_at IS NULL
      AND next_attempt_at IS NULL)
    OR
    (state <> 'failed' AND failed_at IS NULL)
  )
  """
  @workout_sessions_authorization_lane_check "authorization_lane IS NULL OR authorization_lane IN ('ordinary_plan','coach_recommendation','coach_draft','prepared_workout')"
  @workout_sessions_authorization_insert_check """
  (
    NEW.authorization_legacy = 0
    AND (
      (NEW.authorization_lane IS NULL
        AND NEW.authorization_source_id IS NULL
        AND NEW.authorization_fingerprint IS NULL
        AND NEW.plan_id IS NULL
        AND NEW.prepared_workout_id IS NULL)
      OR
      (NEW.authorization_lane = 'ordinary_plan'
        AND NEW.authorization_source_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane IN ('coach_recommendation','coach_draft','prepared_workout')
        AND NEW.authorization_source_id IS NOT NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    )
  )
  """
  @workout_sessions_authorization_update_check """
  (
    (NEW.authorization_legacy = 1
      AND NEW.authorization_lane IS NULL
      AND NEW.authorization_source_id IS NULL
      AND NEW.authorization_fingerprint IS NULL)
    OR
    (NEW.authorization_legacy = 0
      AND (
        (NEW.authorization_lane IS NULL
          AND NEW.authorization_source_id IS NULL
          AND NEW.authorization_fingerprint IS NULL
          AND NEW.plan_id IS NULL
          AND NEW.prepared_workout_id IS NULL)
        OR
        (NEW.authorization_lane = 'ordinary_plan'
          AND NEW.authorization_source_id IS NULL
          AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
        OR
        (NEW.authorization_lane IN ('coach_recommendation','coach_draft','prepared_workout')
          AND NEW.authorization_source_id IS NOT NULL
          AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      ))
  )
  """
  @workout_sessions_authorization_immutable_update_check """
  (
    COALESCE(NEW.authorization_legacy, 0) = COALESCE(OLD.authorization_legacy, 0)
    AND COALESCE(NEW.authorization_lane, '') = COALESCE(OLD.authorization_lane, '')
    AND COALESCE(NEW.authorization_source_id, -1) = COALESCE(OLD.authorization_source_id, -1)
    AND COALESCE(NEW.authorization_fingerprint, '') = COALESCE(OLD.authorization_fingerprint, '')
  )
  """
  @workout_sessions_context_energy_check "COALESCE(NEW.context_low_energy, 0) = 0 OR COALESCE(NEW.context_high_energy, 0) = 0"
  @workout_sessions_primary_limiter_check "primary_limiter IS NULL OR primary_limiter IN ('breathing','whole_body','upper_body','legs')"
  @workout_sessions_preference_feedback_check "preference_feedback IS NULL OR preference_feedback IN ('choose_again','avoid')"
  @workout_videos_format_check "format IN ('follow_along')"

  def up do
    execute(prepared_workouts_table_sql())

    create unique_index(:prepared_workouts, [:user_id, :idempotency_key])

    create unique_index(:prepared_workouts, [:user_id, :slot_key],
             where: "lifecycle IN ('ready','started')",
             name: :prepared_workouts_one_authority_per_slot_index
           )

    create index(:prepared_workouts, [:parent_prepared_workout_id])
    create index(:prepared_workouts, [:workout_plan_id])
    create index(:prepared_workouts, [:execution_program_id])
    create index(:prepared_workouts, [:workout_video_id])
    create index(:prepared_workouts, [:legacy_coach_recommendation_id])
    create index(:prepared_workouts, [:legacy_coach_generation_attempt_id])
    create index(:prepared_workouts, [:legacy_coach_workout_draft_id])
    create index(:prepared_workouts, [:pb_session_id])

    execute(coach_preparation_events_table_sql())

    create unique_index(:coach_preparation_events, [:user_id, :event_key])
    create index(:coach_preparation_events, [:due_at])
    create index(:coach_preparation_events, [:source_session_id])
    create index(:coach_preparation_events, [:fallback_prepared_workout_id])

    create index(:coach_preparation_events, [:state, :next_attempt_at],
             name: :coach_preparation_events_recovery_index
           )

    alter table(:workout_sessions) do
      add :prepared_workout_id, references(:prepared_workouts, on_delete: :nilify_all)
      add :workout_video_id, references(:workout_videos, on_delete: :nilify_all)

      add :authorization_lane, :string,
        check: %{
          name: "workout_sessions_authorization_lane_check",
          expr: @workout_sessions_authorization_lane_check
        }

      add :authorization_legacy, :boolean, null: false, default: false
      add :authorization_source_id, :integer
      add :authorization_fingerprint, :string
      add :context_low_energy, :boolean, null: false, default: false
      add :context_high_energy, :boolean, null: false, default: false
      add :context_heat_affected, :boolean, null: false, default: false

      add :primary_limiter, :string,
        check: %{
          name: "workout_sessions_primary_limiter_check",
          expr: @workout_sessions_primary_limiter_check
        }

      add :preference_feedback, :string,
        check: %{
          name: "workout_sessions_preference_feedback_check",
          expr: @workout_sessions_preference_feedback_check
        }

      add :prescribed_sets_completed, :integer
      add :reps_delta, :integer
      add :shortened, :boolean
      add :recovery_delta_sec, :integer
      add :pace_delta_sec, :float
      add :cadence_decline, :float
    end

    execute("UPDATE workout_sessions SET authorization_legacy = 1")

    create index(:workout_sessions, [:prepared_workout_id])
    create index(:workout_sessions, [:workout_video_id])

    execute(workout_sessions_context_energy_insert_trigger_sql())
    execute(workout_sessions_context_energy_update_trigger_sql())
    execute(workout_sessions_authorization_provenance_insert_trigger_sql())
    execute(workout_sessions_authorization_provenance_update_trigger_sql())

    alter table(:workout_videos) do
      add :available, :boolean, null: false, default: true

      add :format, :string,
        null: false,
        default: "follow_along",
        check: %{name: "workout_videos_format_check", expr: @workout_videos_format_check}
    end
  end

  def down do
    execute("DROP TRIGGER IF EXISTS workout_sessions_authorization_provenance_update_trigger")
    execute("DROP TRIGGER IF EXISTS workout_sessions_authorization_provenance_insert_trigger")
    execute("DROP TRIGGER IF EXISTS workout_sessions_context_energy_update_trigger")
    execute("DROP TRIGGER IF EXISTS workout_sessions_context_energy_insert_trigger")

    drop_if_exists index(:workout_sessions, [:workout_video_id])
    drop_if_exists index(:workout_sessions, [:prepared_workout_id])

    alter table(:workout_sessions) do
      remove :cadence_decline
      remove :pace_delta_sec
      remove :recovery_delta_sec
      remove :shortened
      remove :reps_delta
      remove :prescribed_sets_completed
      remove :preference_feedback
      remove :primary_limiter
      remove :context_heat_affected
      remove :context_high_energy
      remove :context_low_energy
      remove :authorization_fingerprint
      remove :authorization_source_id
      remove :authorization_legacy
      remove :authorization_lane
      remove :workout_video_id
      remove :prepared_workout_id
    end

    alter table(:workout_videos) do
      remove :format
      remove :available
    end

    drop_if_exists index(:coach_preparation_events, [:state, :next_attempt_at],
                     name: :coach_preparation_events_recovery_index
                   )

    drop_if_exists index(:coach_preparation_events, [:fallback_prepared_workout_id])
    drop_if_exists index(:coach_preparation_events, [:source_session_id])
    drop_if_exists index(:coach_preparation_events, [:due_at])
    drop_if_exists unique_index(:coach_preparation_events, [:user_id, :event_key])
    execute("DROP TABLE IF EXISTS coach_preparation_events")

    drop_if_exists index(:prepared_workouts, [:pb_session_id])
    drop_if_exists index(:prepared_workouts, [:legacy_coach_workout_draft_id])
    drop_if_exists index(:prepared_workouts, [:legacy_coach_generation_attempt_id])
    drop_if_exists index(:prepared_workouts, [:legacy_coach_recommendation_id])
    drop_if_exists index(:prepared_workouts, [:workout_video_id])
    drop_if_exists index(:prepared_workouts, [:execution_program_id])
    drop_if_exists index(:prepared_workouts, [:workout_plan_id])
    drop_if_exists index(:prepared_workouts, [:parent_prepared_workout_id])

    drop_if_exists unique_index(:prepared_workouts, [:user_id, :slot_key],
                     where: "lifecycle IN ('ready','started')",
                     name: :prepared_workouts_one_authority_per_slot_index
                   )

    drop_if_exists unique_index(:prepared_workouts, [:user_id, :idempotency_key])
    execute("DROP TABLE IF EXISTS prepared_workouts")
  end

  defp prepared_workouts_table_sql do
    """
    CREATE TABLE prepared_workouts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      lifecycle TEXT NOT NULL,
      selection_kind TEXT NOT NULL,
      trigger TEXT NOT NULL,
      origin TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      slot_key TEXT NOT NULL,
      week_start TEXT NOT NULL,
      available_local_date TEXT NOT NULL,
      revision INTEGER NOT NULL,
      parent_prepared_workout_id INTEGER,
      user_committed INTEGER NOT NULL DEFAULT 0,
      workout_plan_id INTEGER,
      execution_program_id INTEGER,
      execution_program_hash TEXT,
      workout_video_id INTEGER,
      candidate_source_json TEXT,
      candidate_compile_policy_json TEXT,
      candidate_compile_policy_hash TEXT,
      candidate_program_json TEXT,
      candidate_program_hash TEXT,
      legacy_coach_recommendation_id INTEGER,
      legacy_coach_generation_attempt_id INTEGER,
      legacy_coach_workout_draft_id INTEGER,
      compile_policy_json TEXT,
      compile_policy_hash TEXT,
      model TEXT,
      context_hash TEXT,
      prompt_version INTEGER,
      prompt_hash TEXT,
      rationale TEXT,
      intended_stimulus TEXT,
      expected_difficulty TEXT,
      strategy TEXT,
      explored_dimension TEXT,
      evidence_refs_json TEXT NOT NULL,
      catch_up_remaining_sec INTEGER,
      catch_up_duration_min INTEGER,
      capacity_reps INTEGER,
      capacity_provenance TEXT,
      pb_session_id INTEGER,
      pb_reps INTEGER,
      ceiling_reps INTEGER,
      fallback_facts_json TEXT,
      domain_state_token TEXT NOT NULL,
      weekly_watermark INTEGER NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      superseded_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT "prepared_workouts_user_id_fkey"
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      CONSTRAINT "prepared_workouts_parent_prepared_workout_id_fkey"
        FOREIGN KEY (parent_prepared_workout_id) REFERENCES prepared_workouts(id) ON DELETE SET NULL,
      CONSTRAINT "prepared_workouts_workout_plan_id_fkey"
        FOREIGN KEY (workout_plan_id) REFERENCES workout_plans(id) ON DELETE RESTRICT,
      CONSTRAINT "prepared_workouts_execution_program_id_fkey"
        FOREIGN KEY (execution_program_id) REFERENCES execution_programs(id) ON DELETE RESTRICT,
      CONSTRAINT "prepared_workouts_workout_video_id_fkey"
        FOREIGN KEY (workout_video_id) REFERENCES workout_videos(id) ON DELETE RESTRICT,
      CONSTRAINT "prepared_workouts_legacy_coach_recommendation_id_fkey"
        FOREIGN KEY (legacy_coach_recommendation_id) REFERENCES coach_recommendations(id) ON DELETE SET NULL,
      CONSTRAINT "prepared_workouts_legacy_coach_generation_attempt_id_fkey"
        FOREIGN KEY (legacy_coach_generation_attempt_id) REFERENCES coach_generation_attempts(id) ON DELETE SET NULL,
      CONSTRAINT "prepared_workouts_legacy_coach_workout_draft_id_fkey"
        FOREIGN KEY (legacy_coach_workout_draft_id) REFERENCES coach_workout_drafts(id) ON DELETE SET NULL,
      CONSTRAINT "prepared_workouts_pb_session_id_fkey"
        FOREIGN KEY (pb_session_id) REFERENCES workout_sessions(id) ON DELETE SET NULL,
      CONSTRAINT "prepared_workouts_lifecycle_check" CHECK (#{@prepared_workouts_lifecycle_check}),
      CONSTRAINT "prepared_workouts_selection_union_check" CHECK (#{@prepared_workouts_selection_union_check}),
      CONSTRAINT "prepared_workouts_fallback_facts_json_check" CHECK (#{@prepared_workouts_fallback_facts_json_check})
    )
    """
  end

  defp coach_preparation_events_table_sql do
    """
    CREATE TABLE coach_preparation_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      event_key TEXT NOT NULL,
      kind TEXT NOT NULL,
      due_at TEXT NOT NULL,
      state TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      next_attempt_at TEXT,
      lease_owner TEXT,
      lease_expires_at TEXT,
      last_error TEXT,
      source_session_id INTEGER,
      fallback_prepared_workout_id INTEGER,
      prior_week_result_json TEXT,
      completion_outcome TEXT,
      claimed_at TEXT,
      fallback_persisted_at TEXT,
      improving_at TEXT,
      completed_at TEXT,
      failed_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT "coach_preparation_events_user_id_fkey"
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      CONSTRAINT "coach_preparation_events_source_session_id_fkey"
        FOREIGN KEY (source_session_id) REFERENCES workout_sessions(id) ON DELETE SET NULL,
      CONSTRAINT "coach_preparation_events_fallback_prepared_workout_id_fkey"
        FOREIGN KEY (fallback_prepared_workout_id) REFERENCES prepared_workouts(id) ON DELETE SET NULL,
      CONSTRAINT "coach_preparation_events_state_check" CHECK (#{@coach_preparation_events_state_check}),
      CONSTRAINT "coach_preparation_events_state_lease_check" CHECK (#{@coach_preparation_events_state_lease_check}),
      CONSTRAINT "coach_preparation_events_fallback_binding_check" CHECK (#{@coach_preparation_events_fallback_binding_check}),
      CONSTRAINT "coach_preparation_events_retryable_check" CHECK (#{@coach_preparation_events_retryable_check}),
      CONSTRAINT "coach_preparation_events_completion_timestamp_check" CHECK (#{@coach_preparation_events_completion_timestamp_check}),
      CONSTRAINT "coach_preparation_events_completion_outcome_check" CHECK (#{@coach_preparation_events_completion_outcome_check}),
      CONSTRAINT "coach_preparation_events_failed_check" CHECK (#{@coach_preparation_events_failed_check})
    )
    """
  end

  defp workout_sessions_context_energy_insert_trigger_sql do
    """
    CREATE TRIGGER workout_sessions_context_energy_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{@workout_sessions_context_energy_check})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_context_energy_check');
    END
    """
  end

  defp workout_sessions_context_energy_update_trigger_sql do
    """
    CREATE TRIGGER workout_sessions_context_energy_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{@workout_sessions_context_energy_check})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_context_energy_check');
    END
    """
  end

  defp workout_sessions_authorization_provenance_insert_trigger_sql do
    """
    CREATE TRIGGER workout_sessions_authorization_provenance_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{@workout_sessions_authorization_insert_check})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_provenance_check');
    END
    """
  end

  defp workout_sessions_authorization_provenance_update_trigger_sql do
    """
    CREATE TRIGGER workout_sessions_authorization_provenance_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{@workout_sessions_authorization_update_check})
      OR NOT (#{@workout_sessions_authorization_immutable_update_check})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_provenance_check');
    END
    """
  end
end
