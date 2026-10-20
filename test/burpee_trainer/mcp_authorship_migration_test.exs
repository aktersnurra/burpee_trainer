defmodule BurpeeTrainer.McpAuthorshipMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  @migrations Application.app_dir(:burpee_trainer, "priv/repo/migrations")

  # A row left as `claude` would no longer load, and the planner could replace the slot.
  test "what an MCP client planned or wrote is marked mcp, and rolling back restores claude" do
    path = Path.expand(".e2e-artifacts/parallel/db/authorship-#{Ecto.UUID.generate()}.sqlite3")
    start_supervised!({Repo, database: path, pool_size: 1})
    on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1)) end)
    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, to: 20_261_020_000_001, log: false)

    Repo.query!(
      "INSERT INTO users (username,timezone,timezone_provisioned,inserted_at,updated_at) VALUES ('owner','Etc/UTC',1,datetime('now'),datetime('now'))"
    )

    [[user_id]] = Repo.query!("SELECT id FROM users").rows

    # Only `planned_by` matters here, not the selection the table's CHECK requires.
    Repo.query!("PRAGMA ignore_check_constraints = ON")

    for {key, by} <- [{"a", "claude"}, {"b", "owner"}, {"c", "coach"}] do
      Repo.query!(
        "INSERT INTO coach_recommendations (user_id,slot_key,slot_date,planned_by,inserted_at,updated_at) VALUES (?,?,'2026-10-20',?,datetime('now'),datetime('now'))",
        [user_id, key, by]
      )
    end

    Repo.query!(
      "INSERT INTO coach_summaries (user_id,text,metric_ids,source,inserted_at,updated_at) VALUES (?,'Keep Thursday easy.','[]','claude',datetime('now'),datetime('now'))",
      [user_id]
    )

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, all: true, log: false)

    assert Repo.query!("SELECT planned_by FROM coach_recommendations ORDER BY slot_key").rows ==
             [["mcp"], ["owner"], ["coach"]]

    assert Repo.query!("SELECT source FROM coach_summaries").rows == [["mcp"]]

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :down, to: 20_261_020_000_002, log: false)

    assert Repo.query!("SELECT planned_by FROM coach_recommendations ORDER BY slot_key").rows ==
             [["claude"], ["owner"], ["coach"]]

    assert Repo.query!("SELECT source FROM coach_summaries").rows == [["claude"]]
  end
end
