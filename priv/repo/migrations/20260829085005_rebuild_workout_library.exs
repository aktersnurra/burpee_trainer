defmodule BurpeeTrainer.Repo.Migrations.RebuildWorkoutLibrary do
  use Ecto.Migration

  @disable_ddl_transaction true

  @fallback_definition_json ~S|{"burpee_type":"six_count","events":[{"kind":"work","reps":10,"sec_per_burpee":12.0,"sec_per_rep":12.0}],"name":"Built-in Steady 10","pacing_style":"even","rationale":"A steady reusable fallback that works without provider credentials.","target_duration_sec":120,"target_reps":10,"version":1}|
  @fallback_program_json ~S|{"burpee_type":"six_count","events":[{"duration_sec":120.0,"kind":"work","reps":10,"sec_per_burpee_us":12000000,"sec_per_rep_us":12000000}],"schema_version":3,"semantics":{"definition_hash":"3f3fe32fe29452baa76ea5ba52a3559f1e2e0c84a3c7beb7fe289a67ce271b02","pacing_style":"even"},"solver_version":1,"target_duration_ms":120000,"target_reps":10}|
  @fallback_content_hash "0b39f19b165d83aed946acea3071e3bffacb61861d208bd87f29b327e03a9202"

  # These hash the complete normalized sqlite_master catalog: table SQL (including
  # columns, constraints, and FKs), index SQL, trigger bodies, and all object names.
  @source_schema_fingerprint "065f39fa56dc8f7a2d2464de0304499191b4ec7f5bd923a4327f798aaf6d447a"
  @target_schema_fingerprint "ce0d0198f4bd48af3a4a44b095020672136c0f261f0049d05feb620f441420ee"

  @obsolete_tables ~w[
    blocks sets plan_steps execution_programs coach_profiles coach_workout_threads
    coach_messages coach_generation_attempts coach_workout_drafts prepared_workouts
    coach_preparation_events execution_authorization_uses
    video_execution_authorization_uses style_performances
  ]

  @obsolete_triggers ~w[
    workout_sessions_context_energy_insert_trigger
    workout_sessions_context_energy_update_trigger
    workout_sessions_authorization_provenance_insert_trigger
    workout_sessions_authorization_provenance_update_trigger
    workout_sessions_execution_snapshot_insert_trigger
    workout_sessions_execution_snapshot_update_trigger
    prepared_workouts_lifecycle_transition_trigger
    prepared_workouts_selection_immutable_trigger
    prepared_workouts_started_completion_trigger
    coach_workout_drafts_lifecycle_transition_trigger
    coach_workout_drafts_immutable_trigger
  ]

  def up do
    repo().checkout(
      fn ->
        try do
          repo().query!("PRAGMA foreign_keys = OFF")
          assert_pragma_foreign_keys!(0)

          case terminal_state!() do
            :source ->
              {:ok, :ok} =
                repo().transaction(
                  fn ->
                    rebuild_up()
                    flush()
                    validate_complete_target!()
                    :ok
                  end,
                  mode: :immediate,
                  timeout: :infinity
                )

            :target ->
              validate_complete_target!()
          end
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

  defp terminal_state! do
    cond do
      complete_source?() ->
        :source

      complete_target?() ->
        :target

      true ->
        raise "unsupported workout-library migration state: expected a complete source or complete target schema; fingerprint=#{schema_fingerprint()}"
    end
  end

  defp complete_source?, do: schema_fingerprint() == @source_schema_fingerprint
  defp complete_target?, do: schema_fingerprint() == @target_schema_fingerprint

  defp validate_complete_target! do
    unless complete_target?() do
      raise "workout-library target schema validation failed; fingerprint=#{schema_fingerprint()}"
    end

    case repo().query!(
           """
           SELECT COUNT(*) FROM workout_plans
           WHERE user_id IS NULL
             AND name = 'Built-in Steady 10'
             AND origin = 'built_in'
             AND state = 'published'
             AND definition_json = ?
             AND program_json = ?
             AND content_hash = ?
           """,
           [@fallback_definition_json, @fallback_program_json, @fallback_content_hash]
         ).rows do
      [[1]] -> :ok
      rows -> raise "workout-library target fallback validation failed: #{inspect(rows)}"
    end

    assert_database_integrity!()
    assert_target_fact_invariants!()
    assert_sequence_invariants!()
    assert_no_foreign_key_violations!()
  end

  defp rebuild_up do
    plan_sequence = sequence("workout_plans")
    session_sequence = sequence("workout_sessions")
    pose_run_sequence = sequence("pose_capture_runs")

    drop_triggers(@obsolete_triggers)
    drop_final_triggers()

    execute(final_workout_plans_sql())
    execute(final_workout_sessions_sql())

    execute("""
    INSERT INTO workout_sessions_rebuilt (
      id, user_id, state, source_kind, plan_id, goal_id, workout_video_id,
      display_name_snapshot, workout_type_snapshot, program_snapshot,
      video_snapshot, content_hash, client_session_id, started_at, completed_at,
      burpee_type, burpee_count_planned, duration_sec_planned,
      burpee_count_actual, duration_sec_actual, note_pre, note_post, mood, tags,
      capture_mode, cadence_ms, target_pace_sec, pace_consistency,
      context_low_energy, context_high_energy, context_heat_affected,
      primary_limiter, preference_feedback, prescribed_sets_completed,
      reps_delta, shortened, recovery_delta_sec, pace_delta_sec, cadence_decline,
      style_name, rate_per_min_actual, days_since_last, rate_delta,
      rate_avg_rolling_3, time_of_day_bucket, inserted_at, updated_at
    )
    SELECT
      ws.id, ws.user_id, 'completed',
      CASE
        WHEN COALESCE(ws.workout_video_id, ws.video_id) IS NOT NULL THEN 'video'
        WHEN ws.plan_id IS NOT NULL OR ws.execution_program_id IS NOT NULL THEN 'plan'
        ELSE 'manual'
      END,
      NULL, ws.goal_id, wv.id,
      CASE
        WHEN wv.id IS NOT NULL THEN wv.name
        WHEN wp.id IS NOT NULL THEN wp.name
        WHEN ep.id IS NOT NULL THEN
          'Historical ' || replace(COALESCE(ep.burpee_type, ws.burpee_type), '_', ' ') || ' workout'
        ELSE NULL
      END,
      COALESCE(wv.burpee_type, wp.burpee_type, ws.burpee_type),
      ep.program_json,
      CASE WHEN wv.id IS NOT NULL THEN
        json_object(
          'name', wv.name,
          'filename', wv.filename,
          'type', wv.burpee_type,
          'duration', wv.duration_sec,
          'count', wv.burpee_count,
          'format', wv.format
        )
      ELSE NULL END,
      CASE
        WHEN ep.id IS NOT NULL THEN ep.content_hash
        WHEN wv.id IS NOT NULL THEN 'pending-video-hash'
        ELSE NULL
      END,
      ws.client_session_id, NULL, COALESCE(ws.reported_at, ws.inserted_at),
      ws.burpee_type, ws.burpee_count_planned, ws.duration_sec_planned,
      ws.burpee_count_actual, ws.duration_sec_actual, ws.note_pre, ws.note_post,
      ws.mood, ws.tags, ws.capture_mode, ws.cadence_ms, ws.target_pace_sec,
      ws.pace_consistency, ws.context_low_energy, ws.context_high_energy,
      ws.context_heat_affected, ws.primary_limiter, ws.preference_feedback,
      ws.prescribed_sets_completed, ws.reps_delta, ws.shortened,
      ws.recovery_delta_sec, ws.pace_delta_sec, ws.cadence_decline,
      ws.style_name, ws.rate_per_min_actual, ws.days_since_last, ws.rate_delta,
      ws.rate_avg_rolling_3, ws.time_of_day_bucket, ws.inserted_at, ws.updated_at
    FROM workout_sessions AS ws
    LEFT JOIN workout_plans AS wp ON wp.id = ws.plan_id
    LEFT JOIN execution_programs AS ep ON ep.id = ws.execution_program_id
    LEFT JOIN workout_videos AS wv ON wv.id = COALESCE(ws.workout_video_id, ws.video_id)
    WHERE ws.burpee_count_actual IS NOT NULL
      AND ws.duration_sec_actual IS NOT NULL
    ORDER BY ws.id
    """)

    execute(
      "DELETE FROM pose_trace_chunks WHERE pose_capture_run_id NOT IN (SELECT id FROM pose_capture_runs WHERE status = 'completed')"
    )

    execute(final_pose_capture_runs_sql())

    execute("""
    INSERT INTO pose_capture_runs_rebuilt (
      id, user_id, workout_session_id, status, capture_version, started_at,
      completed_at, aborted_at, abort_reason, inserted_at, updated_at
    )
    SELECT id, user_id,
           CASE
             WHEN workout_session_id IN (SELECT id FROM workout_sessions_rebuilt)
               THEN workout_session_id
             ELSE NULL
           END,
           status, capture_version, started_at,
           completed_at, aborted_at, abort_reason, inserted_at, updated_at
    FROM pose_capture_runs
    WHERE status = 'completed'
    ORDER BY id
    """)

    execute("DROP TABLE pose_capture_runs")
    execute("ALTER TABLE pose_capture_runs_rebuilt RENAME TO pose_capture_runs")
    execute("DROP TABLE workout_sessions")
    execute("ALTER TABLE workout_sessions_rebuilt RENAME TO workout_sessions")
    execute("DROP TABLE workout_plans")
    execute("ALTER TABLE workout_plans_rebuilt RENAME TO workout_plans")
    execute("DROP TABLE coach_recommendations")
    execute(final_coach_recommendations_sql())

    Enum.each(@obsolete_tables, &execute("DROP TABLE IF EXISTS #{&1}"))

    create_final_indexes()
    flush()

    restore_sequence("workout_sessions", session_sequence)
    restore_sequence("pose_capture_runs", pose_run_sequence)
    restore_sequence("workout_plans", plan_sequence)
    backfill_video_hashes!()
    insert_fallback!()
    create_final_triggers()
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

  defp final_workout_plans_sql do
    """
    CREATE TABLE workout_plans_rebuilt (
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
      updated_at TEXT NOT NULL,
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
    """
  end

  defp final_coach_recommendations_sql do
    """
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
      updated_at TEXT NOT NULL,
      CONSTRAINT coach_recommendations_selection_check CHECK (
        (selected_workout_plan_id IS NOT NULL AND selected_workout_video_id IS NULL)
        OR (selected_workout_plan_id IS NULL AND selected_workout_video_id IS NOT NULL)
      )
    )
    """
  end

  defp final_workout_sessions_sql do
    """
    CREATE TABLE workout_sessions_rebuilt (
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
    """
  end

  defp final_pose_capture_runs_sql do
    """
    CREATE TABLE pose_capture_runs_rebuilt (
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
    """
  end

  defp create_final_indexes do
    execute("CREATE INDEX IF NOT EXISTS workout_plans_user_id_index ON workout_plans (user_id)")
    execute("CREATE INDEX IF NOT EXISTS workout_plans_state_index ON workout_plans (state)")

    execute(
      "CREATE INDEX IF NOT EXISTS workout_plans_content_hash_index ON workout_plans (content_hash)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS coach_recommendations_user_id_slot_date_index ON coach_recommendations (user_id, slot_date)"
    )

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS coach_recommendations_user_id_slot_key_index ON coach_recommendations (user_id, slot_key)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workout_sessions_user_id_index ON workout_sessions (user_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workout_sessions_user_id_burpee_type_index ON workout_sessions (user_id, burpee_type)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workout_sessions_user_id_inserted_at_index ON workout_sessions (user_id, inserted_at)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workout_sessions_goal_id_index ON workout_sessions (goal_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workout_sessions_plan_id_index ON workout_sessions (plan_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS workout_sessions_workout_video_id_index ON workout_sessions (workout_video_id)"
    )

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS workout_sessions_user_id_client_session_id_index ON workout_sessions (user_id, client_session_id) WHERE client_session_id IS NOT NULL"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS pose_capture_runs_user_id_index ON pose_capture_runs (user_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS pose_capture_runs_workout_session_id_index ON pose_capture_runs (workout_session_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS pose_capture_runs_status_index ON pose_capture_runs (status)"
    )

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS pose_capture_runs_workout_session_id_unique_index ON pose_capture_runs (workout_session_id) WHERE workout_session_id IS NOT NULL"
    )
  end

  defp create_final_triggers do
    execute("""
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
    """)

    execute("""
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
    """)

    execute("""
    CREATE TRIGGER workout_plans_draft_only_delete_trigger
    BEFORE DELETE ON workout_plans
    FOR EACH ROW
    WHEN OLD.state <> 'draft'
    BEGIN
      SELECT RAISE(ABORT, 'workout_plans_draft_only_delete_check');
    END
    """)

    execute("""
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
    """)

    for operation <- ["INSERT", "UPDATE"] do
      suffix = String.downcase(operation)

      execute("""
      CREATE TRIGGER coach_recommendations_pending_draft_#{suffix}_trigger
      BEFORE #{operation} ON coach_recommendations
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
      """)
    end

    for operation <- ["INSERT", "UPDATE"] do
      suffix = String.downcase(operation)

      execute("""
      CREATE TRIGGER workout_sessions_live_plan_snapshot_#{suffix}_trigger
      BEFORE #{operation} ON workout_sessions
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
      """)
    end

    for operation <- ["INSERT", "UPDATE"] do
      suffix = String.downcase(operation)

      execute("""
      CREATE TRIGGER workout_sessions_live_video_snapshot_#{suffix}_trigger
      BEFORE #{operation} ON workout_sessions
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
      """)
    end

    execute("""
    CREATE TRIGGER workout_sessions_state_transition_trigger
    BEFORE UPDATE OF state ON workout_sessions
    FOR EACH ROW
    WHEN NOT (NEW.state = OLD.state OR (OLD.state = 'started' AND NEW.state = 'completed'))
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_state_transition_check');
    END
    """)

    execute("""
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
    """)

    execute("""
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

  defp drop_final_triggers do
    drop_triggers(~w[
      workout_plans_state_transition_trigger
      workout_plans_immutable_content_update_trigger
      workout_plans_draft_only_delete_trigger
      workout_plans_pending_draft_guard_trigger
      coach_recommendations_pending_draft_insert_trigger
      coach_recommendations_pending_draft_update_trigger
      workout_sessions_live_plan_snapshot_insert_trigger
      workout_sessions_live_plan_snapshot_update_trigger
      workout_sessions_live_video_snapshot_insert_trigger
      workout_sessions_live_video_snapshot_update_trigger
      workout_sessions_state_transition_trigger
      workout_sessions_identity_snapshot_immutable_trigger
      workout_sessions_exact_once_completion_trigger
    ])
  end

  defp drop_triggers(names) do
    Enum.each(names, &execute("DROP TRIGGER IF EXISTS #{&1}"))
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

  defp sequence(table) do
    case repo().query!("SELECT seq FROM sqlite_sequence WHERE name = ?", [table]).rows do
      [[value]] when is_integer(value) -> value
      _ -> nil
    end
  end

  defp restore_sequence(table, prior) do
    [[maximum_id]] = repo().query!("SELECT COALESCE(MAX(id), 0) FROM #{table}").rows
    sequence = max(prior || 0, maximum_id)
    repo().query!("DELETE FROM sqlite_sequence WHERE name = ?", [table])
    repo().query!("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", [table, sequence])
  end
end
