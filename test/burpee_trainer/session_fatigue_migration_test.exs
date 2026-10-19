defmodule BurpeeTrainer.SessionFatigueMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  alias BurpeeTrainer.Workouts.WorkoutSession
  import Ecto.Query
  @migrations Path.expand("../../priv/repo/migrations", __DIR__)

  test "backfills completed camera sessions and keeps their inputs locked" do
    path = Path.expand(".e2e-artifacts/parallel/db/fatigue-#{Ecto.UUID.generate()}.sqlite3")
    start_supervised!({Repo, database: path, pool_size: 1})
    on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1)) end)
    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, to: 20_261_016_000_002, log: false)

    Repo.query!(
      "INSERT INTO users (username,timezone,timezone_provisioned,inserted_at,updated_at) VALUES ('fatigue-owner','Etc/UTC',1,datetime('now'),datetime('now'))"
    )

    [[user_id]] = Repo.query!("SELECT id FROM users WHERE username='fatigue-owner'").rows

    # Two sets of four every 5 s with a 10 s rest; the second set lands 2 s late.
    program = %{
      "events" => [
        %{"kind" => "work", "reps" => 4, "sec_per_rep_us" => 5_000_000},
        %{"kind" => "rest", "duration_ms" => 10_000},
        %{"kind" => "work", "reps" => 4, "sec_per_rep_us" => 5_000_000}
      ]
    }

    cadence = [5_000, 10_000, 15_000, 20_000, 37_000, 42_000, 47_000, 52_000]

    for {cadence_ms, snapshot} <- [{Jason.encode!(cadence), Jason.encode!(program)}, {nil, nil}] do
      Repo.query!(
        "INSERT INTO workout_sessions (user_id,state,source_kind,burpee_type,capture_mode,display_name_snapshot,content_hash,burpee_count_actual,duration_sec_actual,cadence_ms,program_snapshot,pace_delta_sec,cadence_decline,completed_at,inserted_at,updated_at) VALUES (?,'completed','plan','six_count','tracked','Fixture','hash',8,60,?,?,9.9,0.5,datetime('now'),datetime('now'),datetime('now'))",
        [user_id, cadence_ms, snapshot]
      )
    end

    Ecto.Migrator.run(Repo, E.migrations(@migrations), :up, all: true, log: false)

    # Read through the schema, so the backfilled values are ones the app can load.
    [camera, plain] = Repo.all(from(s in WorkoutSession, order_by: s.id))
    assert camera.fatigue_coverage == 1.0 and camera.pace_delta_sec == 0.0
    assert camera.recovery_delta_sec == 2.0
    # The second set starts at 30 s: four reps of 5 s, then the 10 s rest.
    assert camera.slip_at_sec == 30.0 and camera.kept_up == false

    assert plain.pace_delta_sec == 9.9 and is_nil(plain.fatigue_coverage) and
             is_nil(plain.kept_up)

    # Fatigue may be recomputed; the reps it was computed from may not change.
    Repo.query!("UPDATE workout_sessions SET kept_up = 1")

    assert_raise Exqlite.Error, ~r/exact_once_completion_check/, fn ->
      Repo.query!("UPDATE workout_sessions SET cadence_ms = '[1]'")
    end
  end
end
