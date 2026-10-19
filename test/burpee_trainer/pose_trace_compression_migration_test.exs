defmodule BurpeeTrainer.PoseTraceCompressionMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  alias BurpeeTrainer.Workouts.PoseTraceChunk
  @migrations Application.app_dir(:burpee_trainer, "priv/repo/migrations")
  @payload ~s({"samples":[{"tMs":0}],"version":1})

  test "compresses stored pose traces, which still read as the JSON they were" do
    path = Path.expand(".e2e-artifacts/parallel/db/traces-#{Ecto.UUID.generate()}.sqlite3")
    start_supervised!({Repo, database: path, pool_size: 1})
    on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1)) end)
    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, to: 20_261_019_000_000, log: false)

    Repo.query!(
      "INSERT INTO users (username,timezone,timezone_provisioned,inserted_at,updated_at) VALUES ('trace-owner','Etc/UTC',1,datetime('now'),datetime('now'))"
    )

    [[user_id]] = Repo.query!("SELECT id FROM users WHERE username='trace-owner'").rows

    Repo.query!(
      "INSERT INTO pose_capture_runs (user_id,status,started_at,inserted_at,updated_at) VALUES (?,'completed',datetime('now'),datetime('now'),datetime('now'))",
      [user_id]
    )

    [[run_id]] = Repo.query!("SELECT id FROM pose_capture_runs").rows

    Repo.query!(
      "INSERT INTO pose_trace_chunks (pose_capture_run_id,segment,chunk_index,started_at_ms,ended_at_ms,sample_count,payload_json,payload_digest,inserted_at,updated_at) VALUES (?,'main',0,0,1000,1,?,'digest',datetime('now'),datetime('now'))",
      [run_id, @payload]
    )

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, all: true, log: false)

    [[stored]] = Repo.query!("SELECT payload_json FROM pose_trace_chunks").rows
    assert :zlib.gunzip(stored) == @payload
    assert [%PoseTraceChunk{payload_json: @payload}] = Repo.all(PoseTraceChunk)

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :down, step: 1, log: false)
    assert Repo.query!("SELECT payload_json FROM pose_trace_chunks").rows == [[@payload]]
  end
end
