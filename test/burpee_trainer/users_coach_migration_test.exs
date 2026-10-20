defmodule BurpeeTrainer.UsersCoachMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  @migrations Application.app_dir(:burpee_trainer, "priv/repo/migrations")

  test "each user keeps the coach they had, and rolling back restores the flag" do
    path = Path.expand(".e2e-artifacts/parallel/db/coach-#{Ecto.UUID.generate()}.sqlite3")
    start_supervised!({Repo, database: path, pool_size: 1})
    on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1)) end)
    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, to: 20_261_020_000_000, log: false)

    for {username, enabled} <- [{"with-coach", 1}, {"with-mcp", 0}] do
      Repo.query!(
        "INSERT INTO users (username,timezone,timezone_provisioned,coach_enabled,inserted_at,updated_at) VALUES (?,'Etc/UTC',1,?,datetime('now'),datetime('now'))",
        [username, enabled]
      )
    end

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, all: true, log: false)

    assert Repo.query!("SELECT username, coach FROM users ORDER BY username").rows ==
             [["with-coach", "app"], ["with-mcp", "mcp"]]

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :down, to: 20_261_020_000_001, log: false)

    assert Repo.query!("SELECT username, coach_enabled FROM users ORDER BY username").rows ==
             [["with-coach", 1], ["with-mcp", 0]]
  end
end
