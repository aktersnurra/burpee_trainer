defmodule BurpeeTrainer.DeletionFirstAtomicMigrationTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo

  @proof_path Path.expand("../support/migrations/atomic_migration_proof.exs", __DIR__)

  setup_all do
    Code.require_file(@proof_path)
    :ok
  end

  setup do
    Application.put_env(:burpee_trainer, :atomic_migration_proof_parent, self())
    task_supervisor = start_supervised!(Task.Supervisor)

    on_exit(fn ->
      Application.delete_env(:burpee_trainer, :atomic_migration_proof_action)
      Application.delete_env(:burpee_trainer, :atomic_migration_proof_parent)
    end)

    {:ok, task_supervisor: task_supervisor}
  end

  test "ordinary exceptions and detected foreign key violations roll back all DDL, data, helpers, and sequences",
       %{task_supervisor: task_supervisor} do
    with_proof_repo(fn repo ->
      before = source_snapshot(repo)
      assert_raise RuntimeError, "atomic proof exception", fn -> migrate(repo, :exception) end
      assert source_snapshot(repo) == before
      assert migration_versions(repo) == []
      assert_all_pool_connections_restored(repo, task_supervisor)
    end)

    with_proof_repo(fn repo ->
      before = source_snapshot(repo)

      assert_raise RuntimeError, "atomic proof foreign key violation", fn ->
        migrate(repo, :foreign_key_violation)
      end

      assert_receive {:atomic_proof_foreign_key_violations, violations}
      assert violations != []
      assert source_snapshot(repo) == before
      assert migration_versions(repo) == []
      assert_all_pool_connections_restored(repo, task_supervisor)
    end)
  end

  test "foreign-key disable verification failure restores the checked-out connection",
       %{task_supervisor: task_supervisor} do
    with_proof_repo(fn repo ->
      assert_raise RuntimeError, "atomic proof foreign key verification failure", fn ->
        migrate(repo, :fk_verification_failure)
      end

      assert migration_versions(repo) == []
      assert_all_pool_connections_restored(repo, task_supervisor)
    end)
  end

  test "abrupt migration owner termination rolls back without sleeps",
       %{task_supervisor: task_supervisor} do
    with_proof_repo(fn repo ->
      before = source_snapshot(repo)

      {:ok, caller_pid} =
        Task.Supervisor.start_child(task_supervisor, fn ->
          migrate(repo, :owner_exit)
        end)

      caller_ref = Process.monitor(caller_pid)
      assert_receive {:atomic_proof_inside_transaction, owner_pid}
      owner_ref = Process.monitor(owner_pid)
      Process.exit(owner_pid, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}
      assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, _reason}

      assert source_snapshot(repo) == before
      assert migration_versions(repo) == []
      assert_all_pool_connections_restored(repo, task_supervisor)
    end)
  end

  test "clean success commits and records the migration version",
       %{task_supervisor: task_supervisor} do
    with_proof_repo(fn repo ->
      migrate(repo, :success)

      assert target_snapshot(repo) == expected_target_snapshot()
      assert migration_versions(repo) == [proof_version()]
      assert_all_pool_connections_restored(repo, task_supervisor)
    end)
  end

  test "complete target without a version row is validated without mutation on retry",
       %{task_supervisor: task_supervisor} do
    with_proof_repo(fn repo ->
      assert_raise RuntimeError, "atomic proof commit/version gap", fn ->
        migrate(repo, :commit_gap)
      end

      assert migration_versions(repo) == []
      assert_all_pool_connections_restored(repo, task_supervisor)
      before_retry = target_snapshot(repo)

      migrate(repo, :success)

      assert target_snapshot(repo) == before_retry
      assert migration_versions(repo) == [proof_version()]
      assert_all_pool_connections_restored(repo, task_supervisor)
    end)
  end

  defp with_proof_repo(fun) do
    database_path =
      Path.join(
        System.tmp_dir!(),
        "atomic-migration-proof-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    Application.put_env(:burpee_trainer, IsolatedMigrationRepo,
      database: database_path,
      pool_size: 5,
      journal_mode: :wal,
      busy_timeout: 10_000,
      stacktrace: true,
      show_sensitive_data_on_connection_error: true
    )

    try do
      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(
                 IsolatedMigrationRepo,
                 fn repo ->
                   setup_source(repo)
                   fun.(repo)
                 end,
                 mode: :temporary,
                 pool_size: 5
               )
    after
      Application.delete_env(:burpee_trainer, IsolatedMigrationRepo)
      File.rm(database_path)
      File.rm("#{database_path}-shm")
      File.rm("#{database_path}-wal")
    end
  end

  defp setup_source(repo) do
    repo.query!("PRAGMA foreign_keys = ON")

    repo.query!("""
    CREATE TABLE atomic_legacy_parents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      value TEXT NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE atomic_legacy_children (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      parent_id INTEGER NOT NULL REFERENCES atomic_legacy_parents(id),
      value TEXT NOT NULL
    )
    """)

    repo.query!("""
    CREATE TRIGGER atomic_legacy_insert_trigger
    AFTER INSERT ON atomic_legacy_parents
    BEGIN
      INSERT INTO atomic_legacy_children (parent_id, value) VALUES (NEW.id, NEW.value);
    END
    """)

    repo.query!("INSERT INTO atomic_legacy_parents (value) VALUES ('legacy')")
    repo.query!("INSERT INTO atomic_legacy_parents (id, value) VALUES (40, 'gap')")
    repo.query!("DELETE FROM atomic_legacy_children WHERE parent_id = 40")
    repo.query!("DELETE FROM atomic_legacy_parents WHERE id = 40")
    assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
  end

  defp migrate(repo, action) do
    Application.put_env(:burpee_trainer, :atomic_migration_proof_action, action)
    Ecto.Migrator.run(repo, [{proof_version(), proof_module()}], :up, all: true)
  end

  defp source_snapshot(repo) do
    %{
      schema:
        schema_rows(repo, [
          "atomic_legacy_parents",
          "atomic_legacy_children",
          "atomic_legacy_insert_trigger"
        ]),
      parents: repo.query!("SELECT id, value FROM atomic_legacy_parents ORDER BY id").rows,
      children:
        repo.query!("SELECT id, parent_id, value FROM atomic_legacy_children ORDER BY id").rows,
      parent_sequence: sequence(repo, "atomic_legacy_parents"),
      child_sequence: sequence(repo, "atomic_legacy_children"),
      target_absent: not table_exists?(repo, "atomic_target"),
      helper_absent: not table_exists?(repo, "atomic_helper"),
      violation_absent: not table_exists?(repo, "atomic_violation")
    }
  end

  defp target_snapshot(repo) do
    %{
      schema: schema_rows(repo, ["atomic_target"]),
      rows: repo.query!("SELECT id, value FROM atomic_target ORDER BY id").rows,
      sequence: sequence(repo, "atomic_target"),
      source_absent:
        not table_exists?(repo, "atomic_legacy_parents") and
          not table_exists?(repo, "atomic_legacy_children"),
      helper_absent: not table_exists?(repo, "atomic_helper"),
      violations: repo.query!("PRAGMA foreign_key_check").rows
    }
  end

  defp expected_target_snapshot do
    %{
      schema: [
        [
          "table",
          "atomic_target",
          "CREATE TABLE atomic_target (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
        ]
      ],
      rows: [[1, "legacy"]],
      sequence: 900,
      source_absent: true,
      helper_absent: true,
      violations: []
    }
  end

  defp schema_rows(repo, names) do
    placeholders = Enum.map_join(names, ",", fn _ -> "?" end)

    repo.query!(
      "SELECT type, name, sql FROM sqlite_master WHERE name IN (#{placeholders}) ORDER BY name",
      names
    ).rows
  end

  defp migration_versions(repo) do
    repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
    |> List.flatten()
  end

  defp sequence(repo, table) do
    case repo.query!("SELECT seq FROM sqlite_sequence WHERE name = ?", [table]).rows do
      [[value]] -> value
      [] -> nil
    end
  end

  defp table_exists?(repo, table) do
    repo.query!("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table]).rows !=
      []
  end

  defp assert_all_pool_connections_restored(repo, task_supervisor) do
    parent = self()

    tasks =
      for _ <- 1..5 do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          repo.checkout(
            fn ->
              send(parent, {:atomic_proof_connection_checked_out, self()})

              receive do
                :check_atomic_proof_connection ->
                  {
                    repo.query!("PRAGMA foreign_keys").rows,
                    repo.query!("PRAGMA foreign_key_check").rows
                  }
              end
            end,
            timeout: :infinity
          )
        end)
      end

    holders =
      for _ <- 1..5 do
        assert_receive {:atomic_proof_connection_checked_out, holder}, 5_000
        holder
      end

    Enum.each(holders, &send(&1, :check_atomic_proof_connection))
    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate({[[1]], []}, 5)
  end

  defp proof_module, do: BurpeeTrainer.TestSupport.AtomicMigrationProof
  defp proof_version, do: apply(proof_module(), :version, [])
end
