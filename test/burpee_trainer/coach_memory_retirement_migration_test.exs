defmodule BurpeeTrainer.CoachMemoryRetirementMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  @migrations Path.expand("../../priv/repo/migrations", __DIR__)
  test "carries ordered guidance to bounded notebooks and retires actual legacy tables" do
    path = Path.expand(".e2e-artifacts/parallel/db/retirement-#{Ecto.UUID.generate()}.sqlite3")
    start_supervised!({Repo, database: path, pool_size: 1})
    assert [[0, "main", ^path]] = Repo.query!("PRAGMA database_list").rows
    on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1)) end)
    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, to: 20_261_008_192_443, log: false)

    Repo.query!(
      "INSERT INTO users (username,timezone,timezone_provisioned,inserted_at,updated_at) VALUES ('migration-owner','Etc/UTC',1,datetime('now'),datetime('now'))"
    )

    [[id]] = Repo.query!("SELECT id FROM users WHERE username='migration-owner'").rows

    Repo.query!(
      "INSERT INTO coach_guidance_entries (user_id,text,kind,summary,inserted_at,updated_at) VALUES (?, 'old text','lasting','Prefers short sets',datetime('now'),datetime('now')), (?, 'Knee is sore','pending',NULL,datetime('now'),datetime('now'))",
      [id, id]
    )

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, all: true, log: false)
    [[body]] = Repo.query!("SELECT body FROM coach_notebooks WHERE user_id=?", [id]).rows
    assert body == "From earlier notes:\n- Prefers short sets\n- Knee is sore"

    assert Repo.query!(
             "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('coach_guidance_entries','coach_workout_memories','workout_design_sessions','workout_design_entries')"
           ).rows == []

    refute Enum.any?(
             Repo.query!("PRAGMA table_info(workout_plans)").rows,
             &(Enum.at(&1, 1) == "design_session_id")
           )

    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end
end
