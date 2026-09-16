defmodule BurpeeTrainer.VideoExecutionAuthorizationMigrationTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo

  @project_root Path.expand("../..", __DIR__)
  @previous_version 20_260_825_224_209
  @migration_version 20_260_826_213_050

  test "dev migration preserves existing sessions and leaves the database migratable" do
    database_path =
      Path.join(
        "/tmp",
        "adaptive-home-coach-e2e-migration-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    fixture_env = [
      {"MIX_ENV", "dev"},
      {"E2E_ADAPTIVE_FIXTURE", "1"},
      {"E2E_ADAPTIVE_DATABASE_PATH", database_path}
    ]

    Application.put_env(:burpee_trainer, IsolatedMigrationRepo,
      database: database_path,
      pool_size: 1
    )

    try do
      run_fixture_mix!(["ecto.create", "--quiet"], fixture_env)
      run_fixture_mix!(["ecto.migrate", "--to", "#{@previous_version}", "--quiet"], fixture_env)

      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(
                 IsolatedMigrationRepo,
                 fn repo ->
                   repo.query!("""
                   INSERT INTO users (username, password_hash, inserted_at, updated_at)
                   VALUES ('migration-user', 'hash', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                   """)

                   repo.query!("""
                   INSERT INTO workout_sessions (user_id, burpee_type, inserted_at, updated_at)
                   VALUES (1, 'six_count', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                   """)
                 end,
                 mode: :temporary,
                 pool_size: 1
               )

      run_fixture_mix!(["ecto.migrate", "--to", "#{@migration_version}", "--quiet"], fixture_env)

      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(
                 IsolatedMigrationRepo,
                 fn repo ->
                   assert repo.query!("SELECT id, user_id FROM workout_sessions").rows == [[1, 1]]

                   assert repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [
                            @migration_version
                          ]).rows == [[@migration_version]]
                 end,
                 mode: :temporary,
                 pool_size: 1
               )
    after
      Application.delete_env(:burpee_trainer, IsolatedMigrationRepo)
      File.rm(database_path)
      File.rm("#{database_path}-shm")
      File.rm("#{database_path}-wal")
    end
  end

  test "fresh dev database migrates through the latest schema" do
    database_path =
      Path.join(
        "/tmp",
        "adaptive-home-coach-e2e-migration-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    fixture_env = [
      {"MIX_ENV", "dev"},
      {"E2E_ADAPTIVE_FIXTURE", "1"},
      {"E2E_ADAPTIVE_DATABASE_PATH", database_path}
    ]

    Application.put_env(:burpee_trainer, IsolatedMigrationRepo,
      database: database_path,
      pool_size: 1
    )

    try do
      run_fixture_mix!(["ecto.create", "--quiet"], fixture_env)
      run_fixture_mix!(["ecto.migrate", "--quiet"], fixture_env)

      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(
                 IsolatedMigrationRepo,
                 fn repo ->
                   assert repo.query!("SELECT COUNT(*) FROM workout_sessions").rows == [[0]]

                   assert repo.query!("SELECT MAX(version) FROM schema_migrations").rows == [
                            [20_260_928_202_639]
                          ]
                 end,
                 mode: :temporary,
                 pool_size: 1
               )
    after
      Application.delete_env(:burpee_trainer, IsolatedMigrationRepo)
      File.rm(database_path)
      File.rm("#{database_path}-shm")
      File.rm("#{database_path}-wal")
    end
  end

  defp run_fixture_mix!(args, env) do
    {output, status} =
      System.cmd("mix", args,
        cd: @project_root,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n#{output}"
  end
end
