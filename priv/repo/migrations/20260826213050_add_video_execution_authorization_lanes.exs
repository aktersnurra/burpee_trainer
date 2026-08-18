defmodule BurpeeTrainer.Repo.Migrations.AddVideoExecutionAuthorizationLanes do
  use Ecto.Migration

  @disable_ddl_transaction true

  @plan_lanes "'ordinary_plan','coach_recommendation','coach_draft','prepared_workout'"
  @all_lanes @plan_lanes <> ",'manual_video','prepared_video'"

  @columns ~w[id user_id plan_id goal_id video_id status source report_fingerprint report_pending_at reported_at aborted_at burpee_type burpee_count_planned duration_sec_planned burpee_count_actual duration_sec_actual note_pre note_post mood tags style_name rate_per_min_actual days_since_last rate_delta rate_avg_rolling_3 time_of_day_bucket inserted_at updated_at capture_mode cadence_ms target_pace_sec pace_consistency client_session_id execution_program_id prepared_workout_id workout_video_id authorization_lane authorization_legacy authorization_source_id authorization_fingerprint context_low_energy context_high_energy context_heat_affected primary_limiter preference_feedback prescribed_sets_completed reps_delta shortened recovery_delta_sec pace_delta_sec cadence_decline]

  @immutable_check """
  COALESCE(NEW.authorization_legacy, 0) = COALESCE(OLD.authorization_legacy, 0)
  AND COALESCE(NEW.authorization_lane, '') = COALESCE(OLD.authorization_lane, '')
  AND COALESCE(NEW.authorization_source_id, -1) = COALESCE(OLD.authorization_source_id, -1)
  AND COALESCE(NEW.authorization_fingerprint, '') = COALESCE(OLD.authorization_fingerprint, '')
  AND (
    NEW.workout_video_id IS OLD.workout_video_id
    OR (OLD.workout_video_id IS NOT NULL AND NEW.workout_video_id IS NULL)
  )
  """

  def up do
    rebuild(:up)
    create_video_execution_authorization_uses()
  end

  def down do
    reject_live_video_authorizations!()
    drop_if_exists(table(:video_execution_authorization_uses))
    flush()
    rebuild(:down)
  end

  defp reject_live_video_authorizations! do
    case repo().query!(
           "SELECT COUNT(*) FROM workout_sessions WHERE authorization_lane IN ('manual_video','prepared_video')"
         ).rows do
      [[0]] ->
        reject_durable_video_authorization_uses!()

      [[count]] ->
        raise "cannot roll back video execution authorization lanes while live video-authorized sessions exist (count=#{count})"
    end
  end

  defp reject_durable_video_authorization_uses! do
    if table_exists?("video_execution_authorization_uses") do
      case repo().query!("SELECT COUNT(*) FROM video_execution_authorization_uses").rows do
        [[0]] ->
          :ok

        [[count]] ->
          raise "cannot roll back video execution authorization lanes while durable video authorization uses exist (count=#{count})"
      end
    else
      :ok
    end
  end

  defp table_exists?(name) do
    repo().query!(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
      [name]
    ).rows == [[1]]
  end

  defp create_video_execution_authorization_uses do
    execute("DROP TABLE IF EXISTS video_execution_authorization_uses")

    execute("""
    CREATE TABLE video_execution_authorization_uses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL CONSTRAINT "video_execution_authorization_uses_user_id_fkey" REFERENCES users(id) ON DELETE CASCADE,
      workout_video_id INTEGER CONSTRAINT "video_execution_authorization_uses_workout_video_id_fkey" REFERENCES workout_videos(id) ON DELETE SET NULL,
      authorization_lane TEXT NOT NULL CONSTRAINT video_execution_authorization_uses_authorization_lane_check CHECK (authorization_lane IN ('manual_video','prepared_video')),
      authorization_source_id INTEGER NOT NULL,
      authorization_fingerprint TEXT NOT NULL,
      authorization_nonce TEXT NOT NULL,
      client_session_id TEXT NOT NULL,
      workout_session_id INTEGER CONSTRAINT "video_execution_authorization_uses_workout_session_id_fkey" REFERENCES workout_sessions(id) ON DELETE SET NULL,
      consumed_at TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute(
      "CREATE UNIQUE INDEX video_execution_authorization_uses_authorization_fingerprint_index ON video_execution_authorization_uses (authorization_fingerprint)"
    )

    execute(
      "CREATE UNIQUE INDEX video_execution_authorization_uses_user_id_client_session_id_index ON video_execution_authorization_uses (user_id, client_session_id)"
    )

    execute(
      "CREATE INDEX video_execution_authorization_uses_workout_session_id_index ON video_execution_authorization_uses (workout_session_id)"
    )

    execute(
      "CREATE INDEX video_execution_authorization_uses_workout_video_id_index ON video_execution_authorization_uses (workout_video_id)"
    )

    flush()
  end

  defp rebuild(direction) do
    prior_sequence = workout_sessions_sequence()

    execute("PRAGMA foreign_keys = OFF")
    execute("DROP TABLE IF EXISTS workout_sessions_video_auth_rebuilt")
    execute(table_sql(direction))
    execute(copy_sql(direction))
    execute("DROP TABLE workout_sessions")
    execute("ALTER TABLE workout_sessions_video_auth_rebuilt RENAME TO workout_sessions")
    create_indexes(direction)
    create_context_triggers()
    create_provenance_triggers(direction)
    flush()
    restore_workout_sessions_sequence(prior_sequence)
    execute("PRAGMA foreign_keys = ON")
  end

  defp workout_sessions_sequence do
    case repo().query!("SELECT seq FROM sqlite_sequence WHERE name = 'workout_sessions'").rows do
      [[sequence]] when is_integer(sequence) -> sequence
      _other -> nil
    end
  end

  defp restore_workout_sessions_sequence(nil), do: :ok

  defp restore_workout_sessions_sequence(prior_sequence) do
    [[current_sequence]] =
      repo().query!(
        "SELECT COALESCE(MAX(seq), 0) FROM sqlite_sequence WHERE name = 'workout_sessions'"
      ).rows

    [[maximum_id]] =
      repo().query!("SELECT COALESCE(MAX(id), 0) FROM workout_sessions").rows

    sequence = max(prior_sequence, max(current_sequence, maximum_id))
    repo().query!("DELETE FROM sqlite_sequence WHERE name = 'workout_sessions'")

    repo().query!(
      "INSERT INTO sqlite_sequence (name, seq) VALUES ('workout_sessions', ?)",
      [sequence]
    )

    :ok
  end

  defp table_sql(direction) do
    lanes = if direction == :up, do: @all_lanes, else: @plan_lanes

    """
    CREATE TABLE workout_sessions_video_auth_rebuilt (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL CONSTRAINT "workout_sessions_user_id_fkey" REFERENCES users(id) ON DELETE CASCADE,
      plan_id INTEGER CONSTRAINT "workout_sessions_plan_id_fkey" REFERENCES workout_plans(id) ON DELETE SET NULL,
      goal_id INTEGER CONSTRAINT "workout_sessions_goal_id_fkey" REFERENCES goals(id) ON DELETE SET NULL,
      video_id INTEGER CONSTRAINT "workout_sessions_video_id_fkey" REFERENCES workout_videos(id) ON DELETE SET NULL,
      status TEXT DEFAULT 'reported' NOT NULL,
      source TEXT DEFAULT 'manual' NOT NULL,
      report_fingerprint TEXT,
      report_pending_at TEXT,
      reported_at TEXT,
      aborted_at TEXT,
      burpee_type TEXT NOT NULL,
      burpee_count_planned INTEGER,
      duration_sec_planned INTEGER,
      burpee_count_actual INTEGER,
      duration_sec_actual INTEGER,
      note_pre TEXT,
      note_post TEXT,
      mood INTEGER,
      tags TEXT,
      style_name TEXT,
      rate_per_min_actual NUMERIC,
      days_since_last INTEGER,
      rate_delta NUMERIC,
      rate_avg_rolling_3 NUMERIC,
      time_of_day_bucket TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      capture_mode TEXT DEFAULT 'logged' NOT NULL,
      cadence_ms TEXT,
      target_pace_sec NUMERIC,
      pace_consistency NUMERIC,
      client_session_id TEXT,
      execution_program_id INTEGER CONSTRAINT "workout_sessions_execution_program_id_fkey" REFERENCES execution_programs(id) ON DELETE SET NULL,
      prepared_workout_id INTEGER CONSTRAINT "workout_sessions_prepared_workout_id_fkey" REFERENCES prepared_workouts(id) ON DELETE SET NULL,
      workout_video_id INTEGER CONSTRAINT "workout_sessions_workout_video_id_fkey" REFERENCES workout_videos(id) ON DELETE SET NULL,
      authorization_lane TEXT CONSTRAINT workout_sessions_authorization_lane_check CHECK (authorization_lane IS NULL OR authorization_lane IN (#{lanes})),
      authorization_legacy INTEGER DEFAULT false NOT NULL,
      authorization_source_id INTEGER,
      authorization_fingerprint TEXT,
      context_low_energy INTEGER DEFAULT false NOT NULL,
      context_high_energy INTEGER DEFAULT false NOT NULL,
      context_heat_affected INTEGER DEFAULT false NOT NULL,
      primary_limiter TEXT CONSTRAINT workout_sessions_primary_limiter_check CHECK (primary_limiter IS NULL OR primary_limiter IN ('breathing','whole_body','upper_body','legs')),
      preference_feedback TEXT CONSTRAINT workout_sessions_preference_feedback_check CHECK (preference_feedback IS NULL OR preference_feedback IN ('choose_again','avoid')),
      prescribed_sets_completed INTEGER,
      reps_delta INTEGER,
      shortened INTEGER,
      recovery_delta_sec INTEGER,
      pace_delta_sec NUMERIC,
      cadence_decline NUMERIC
    )
    """
  end

  defp copy_sql(:up) do
    columns = Enum.join(@columns, ", ")

    "INSERT INTO workout_sessions_video_auth_rebuilt (#{columns}) SELECT #{columns} FROM workout_sessions"
  end

  defp copy_sql(:down) do
    columns = Enum.join(@columns, ", ")

    "INSERT INTO workout_sessions_video_auth_rebuilt (#{columns}) SELECT #{columns} FROM workout_sessions"
  end

  defp create_indexes(direction) do
    execute("CREATE INDEX workout_sessions_user_id_index ON workout_sessions (user_id)")

    execute(
      "CREATE INDEX workout_sessions_user_id_burpee_type_index ON workout_sessions (user_id, burpee_type)"
    )

    execute(
      "CREATE INDEX workout_sessions_user_id_inserted_at_index ON workout_sessions (user_id, inserted_at)"
    )

    execute("CREATE INDEX workout_sessions_goal_id_index ON workout_sessions (goal_id)")
    execute("CREATE INDEX workout_sessions_capture_mode_index ON workout_sessions (capture_mode)")

    execute(
      "CREATE UNIQUE INDEX workout_sessions_user_id_client_session_id_index ON workout_sessions (user_id, client_session_id)"
    )

    execute(
      "CREATE INDEX workout_sessions_execution_program_id_index ON workout_sessions (execution_program_id)"
    )

    execute(
      "CREATE INDEX workout_sessions_prepared_workout_id_index ON workout_sessions (prepared_workout_id)"
    )

    execute(
      "CREATE INDEX workout_sessions_workout_video_id_index ON workout_sessions (workout_video_id)"
    )

    if direction == :up do
      execute(
        "CREATE UNIQUE INDEX workout_sessions_authorization_fingerprint_index ON workout_sessions (authorization_fingerprint) WHERE authorization_fingerprint IS NOT NULL"
      )
    end
  end

  defp create_context_triggers do
    for operation <- ["INSERT", "UPDATE"] do
      name = String.downcase(operation)

      execute("""
      CREATE TRIGGER workout_sessions_context_energy_#{name}_trigger
      BEFORE #{operation} ON workout_sessions
      FOR EACH ROW
      WHEN NOT (COALESCE(NEW.context_low_energy, 0) = 0 OR COALESCE(NEW.context_high_energy, 0) = 0)
      BEGIN
        SELECT RAISE(ABORT, 'workout_sessions_context_energy_check');
      END
      """)
    end
  end

  defp create_provenance_triggers(direction) do
    insert_check = authorization_insert_check(direction)
    update_check = authorization_update_check(direction)

    execute("""
    CREATE TRIGGER workout_sessions_authorization_provenance_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{insert_check})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_provenance_check');
    END
    """)

    execute("""
    CREATE TRIGGER workout_sessions_authorization_provenance_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{update_check}) OR NOT (#{@immutable_check})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_provenance_check');
    END
    """)
  end

  defp authorization_insert_check(direction) do
    """
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
      #{video_insert_members(direction)}
    )
    """
  end

  defp authorization_update_check(direction) do
    """
    (NEW.authorization_legacy = 1
      AND NEW.authorization_lane IS NULL
      AND NEW.authorization_source_id IS NULL
      AND NEW.authorization_fingerprint IS NULL)
    OR (#{authorization_insert_check(direction)})
    OR (#{video_tombstone_update_check(direction)})
    """
  end

  defp video_tombstone_update_check(:up) do
    """
    NEW.authorization_legacy = 0
    AND OLD.workout_video_id IS NOT NULL
    AND NEW.workout_video_id IS NULL
    AND NEW.plan_id IS NULL
    AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> ''
    AND (
      (NEW.authorization_lane = 'manual_video'
        AND NEW.authorization_source_id = OLD.workout_video_id
        AND NEW.prepared_workout_id IS NULL)
      OR
      (NEW.authorization_lane = 'prepared_video'
        AND NEW.authorization_source_id IS NOT NULL)
    )
    """
  end

  defp video_tombstone_update_check(:down), do: "0"

  defp video_insert_members(:up) do
    """
    OR
    (NEW.authorization_lane = 'manual_video'
      AND NEW.authorization_source_id = NEW.workout_video_id
      AND NEW.plan_id IS NULL
      AND NEW.prepared_workout_id IS NULL
      AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    OR
    (NEW.authorization_lane = 'prepared_video'
      AND NEW.authorization_source_id = NEW.prepared_workout_id
      AND NEW.workout_video_id IS NOT NULL
      AND NEW.plan_id IS NULL
      AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    """
  end

  defp video_insert_members(:down), do: ""
end
