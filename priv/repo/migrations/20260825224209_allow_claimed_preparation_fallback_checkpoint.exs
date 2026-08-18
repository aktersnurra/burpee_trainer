defmodule BurpeeTrainer.Repo.Migrations.AllowClaimedPreparationFallbackCheckpoint do
  use Ecto.Migration

  @moduledoc false

  def up, do: rebuild_table(claimed_fallback_check(), :up)

  def down, do: rebuild_table(original_fallback_check(), :down)

  defp rebuild_table(fallback_check, direction) do
    execute("DROP TABLE IF EXISTS coach_preparation_events_rebuilt")
    execute(table_sql(fallback_check))

    execute(copy_sql(direction))

    execute("DROP TABLE coach_preparation_events")
    execute("ALTER TABLE coach_preparation_events_rebuilt RENAME TO coach_preparation_events")

    create unique_index(:coach_preparation_events, [:user_id, :event_key])
    create index(:coach_preparation_events, [:due_at])
    create index(:coach_preparation_events, [:source_session_id])
    create index(:coach_preparation_events, [:fallback_prepared_workout_id])

    create index(:coach_preparation_events, [:state, :next_attempt_at],
             name: :coach_preparation_events_recovery_index
           )
  end

  defp claimed_fallback_check do
    """
    (
      (state IN ('fallback_persisted','improving','retryable','completed')
        AND fallback_prepared_workout_id IS NOT NULL
        AND fallback_persisted_at IS NOT NULL)
      OR
      (state = 'claimed'
        AND ((fallback_prepared_workout_id IS NULL AND fallback_persisted_at IS NULL)
          OR (fallback_prepared_workout_id IS NOT NULL AND fallback_persisted_at IS NOT NULL)))
      OR
      (state IN ('pending','failed')
        AND fallback_prepared_workout_id IS NULL
        AND fallback_persisted_at IS NULL)
    )
    """
  end

  defp original_fallback_check do
    """
    (
      (state IN ('fallback_persisted','improving','retryable','completed')
        AND fallback_prepared_workout_id IS NOT NULL)
      OR
      (state IN ('pending','claimed','failed')
        AND fallback_prepared_workout_id IS NULL)
    )
    """
  end

  defp copy_sql(:up) do
    copy_sql(
      "state",
      "lease_owner",
      "lease_expires_at",
      "CASE WHEN fallback_prepared_workout_id IS NOT NULL THEN COALESCE(fallback_persisted_at, improving_at, claimed_at, updated_at, inserted_at) ELSE NULL END"
    )
  end

  defp copy_sql(:down) do
    copy_sql(
      "CASE WHEN state = 'claimed' AND fallback_prepared_workout_id IS NOT NULL THEN 'fallback_persisted' ELSE state END",
      "CASE WHEN state = 'claimed' AND fallback_prepared_workout_id IS NOT NULL THEN NULL ELSE lease_owner END",
      "CASE WHEN state = 'claimed' AND fallback_prepared_workout_id IS NOT NULL THEN NULL ELSE lease_expires_at END",
      "fallback_persisted_at"
    )
  end

  defp copy_sql(state, lease_owner, lease_expires_at, fallback_persisted_at) do
    """
    INSERT INTO coach_preparation_events_rebuilt (
      id, user_id, event_key, kind, due_at, state, attempt_count, next_attempt_at,
      lease_owner, lease_expires_at, last_error, source_session_id,
      fallback_prepared_workout_id, prior_week_result_json, completion_outcome,
      claimed_at, fallback_persisted_at, improving_at, completed_at, failed_at,
      inserted_at, updated_at
    )
    SELECT
      id, user_id, event_key, kind, due_at, #{state}, attempt_count, next_attempt_at,
      #{lease_owner}, #{lease_expires_at}, last_error, source_session_id,
      fallback_prepared_workout_id, prior_week_result_json, completion_outcome,
      claimed_at, #{fallback_persisted_at}, improving_at, completed_at, failed_at,
      inserted_at, updated_at
    FROM coach_preparation_events
    """
  end

  defp table_sql(fallback_check) do
    """
    CREATE TABLE coach_preparation_events_rebuilt (
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
      CONSTRAINT "coach_preparation_events_state_check"
        CHECK (state IN ('pending','claimed','fallback_persisted','improving','retryable','completed','failed')),
      CONSTRAINT "coach_preparation_events_state_lease_check" CHECK (
        (state IN ('claimed','improving')
          AND TRIM(COALESCE(lease_owner, '')) <> ''
          AND lease_expires_at IS NOT NULL)
        OR
        (state NOT IN ('claimed','improving')
          AND lease_owner IS NULL
          AND lease_expires_at IS NULL)
      ),
      CONSTRAINT "coach_preparation_events_fallback_binding_check" CHECK (#{fallback_check}),
      CONSTRAINT "coach_preparation_events_retryable_check" CHECK (
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
      ),
      CONSTRAINT "coach_preparation_events_completion_timestamp_check" CHECK (
        (state = 'completed' AND completed_at IS NOT NULL)
        OR (state <> 'completed' AND completed_at IS NULL)
      ),
      CONSTRAINT "coach_preparation_events_completion_outcome_check" CHECK (
        (state = 'completed'
          AND completion_outcome IS NOT NULL
          AND completion_outcome IN ('improved','fallback'))
        OR (state <> 'completed' AND completion_outcome IS NULL)
      ),
      CONSTRAINT "coach_preparation_events_failed_check" CHECK (
        (state = 'failed'
          AND failed_at IS NOT NULL
          AND fallback_prepared_workout_id IS NULL
          AND completed_at IS NULL
          AND completion_outcome IS NULL
          AND lease_owner IS NULL
          AND lease_expires_at IS NULL
          AND next_attempt_at IS NULL)
        OR (state <> 'failed' AND failed_at IS NULL)
      )
    )
    """
  end
end
