defmodule BurpeeTrainer.GoalDurationMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  @migrations Application.app_dir(:burpee_trainer, "priv/repo/migrations")

  test "open goals become 20-minute goals with the same reps; finished ones keep theirs" do
    path = Path.expand(".e2e-artifacts/parallel/db/goals-#{Ecto.UUID.generate()}.sqlite3")
    start_supervised!({Repo, database: path, pool_size: 1})
    on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1)) end)
    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, to: 20_261_020_000_000, log: false)

    Repo.query!(
      "INSERT INTO users (username,timezone,timezone_provisioned,inserted_at,updated_at) VALUES ('goal-owner','Etc/UTC',1,datetime('now'),datetime('now'))"
    )

    [[user_id]] = Repo.query!("SELECT id FROM users WHERE username='goal-owner'").rows

    for {type, duration, status} <- [
          {"six_count", 1714, "active"},
          {"navy_seal", 1600, "proposed"},
          {"six_count", 1846, "abandoned"}
        ] do
      Repo.query!(
        "INSERT INTO goals (user_id,burpee_type,burpee_count_target,duration_sec_target,date_target,burpee_count_baseline,duration_sec_baseline,date_baseline,status,inserted_at,updated_at) VALUES (?,?,200,?,'2026-11-01',140,1200,'2026-10-01',?,datetime('now'),datetime('now'))",
        [user_id, type, duration, status]
      )
    end

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, all: true, log: false)

    assert Repo.query!(
             "SELECT status, burpee_count_target, duration_sec_target FROM goals ORDER BY id"
           ).rows == [["active", 200, 1200], ["proposed", 200, 1200], ["abandoned", 200, 1846]]
  end
end
