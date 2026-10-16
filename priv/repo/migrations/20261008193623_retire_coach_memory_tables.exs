defmodule BurpeeTrainer.Repo.Migrations.RetireCoachMemoryTables do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO coach_notebooks (user_id, body, inserted_at, updated_at)
    SELECT user_id, substr('From earlier notes:' || char(10) || '- ' || group_concat(note, char(10) || '- '), 1, 4000), strftime('%Y-%m-%d %H:%M:%f','now'), strftime('%Y-%m-%d %H:%M:%f','now')
    FROM (SELECT user_id, COALESCE(NULLIF(summary, ''), text) AS note FROM coach_guidance_entries ORDER BY user_id, id)
    GROUP BY user_id
    ON CONFLICT(user_id) DO UPDATE SET body = substr(CASE WHEN coach_notebooks.body = '' THEN excluded.body ELSE coach_notebooks.body || char(10) || char(10) || excluded.body END, 1, 4000), updated_at = excluded.updated_at
    """)

    for [name] <-
          repo().query!(
            "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name IN ('coach_guidance_entries','coach_workout_memories','workout_design_sessions','workout_design_entries')"
          ).rows do
      execute("DROP TRIGGER \"#{String.replace(name, "\"", "\"\"")}\"")
    end

    execute("DROP TABLE coach_guidance_entries")
    execute("DROP TABLE coach_workout_memories")
    execute("DROP TABLE workout_design_entries")
    execute("ALTER TABLE workout_plans DROP COLUMN design_session_id")
    execute("DROP TABLE workout_design_sessions")
  end

  def down, do: raise("Coach memory retirement cannot reconstruct discarded audit logs")
end
