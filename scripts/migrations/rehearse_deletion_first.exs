defmodule BurpeeTrainer.DeletionFirstRehearsal do
  @moduledoc false

  alias BurpeeTrainer.DeletionFirstMigrationTest, as: Contract
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo

  @source "/tmp/deletion-first-source-backup.db"
  @target "/tmp/deletion-first-migration-rehearsal.db"
  @allowed [@source, @target]
  @sidecars ["", "-shm", "-wal"]
  @migration_dir Path.expand("../../priv/repo/migrations", __DIR__)
  @redesign_glob Path.join(@migration_dir, "*_rebuild_workout_library.exs")

  @spec main() :: :ok
  def main do
    require_test_environment!()
    reject_arguments!()
    validate_paths!()

    repo_config = Application.get_env(:burpee_trainer, BurpeeTrainer.Repo)
    assert_application_repo_stopped!()
    start_test_dependencies!()
    load_contract!()

    clear_allowed_paths!()

    report =
      try do
        run_rehearsal!()
      after
        stop_isolated_repo()
        clear_allowed_paths!()
      end

    assert_application_repo_stopped!()

    if Application.get_env(:burpee_trainer, BurpeeTrainer.Repo) != repo_config do
      raise "application Repo configuration changed during rehearsal"
    end

    IO.puts("DELETION_FIRST_REHEARSAL=" <> Jason.encode!(report))
    :ok
  end

  defp run_rehearsal! do
    migrations = migrations!()
    source_version = Contract.rehearsal_source_version()
    redesign_version = redesign_version!()

    historical_pid = start_isolated_repo!(@source, 1)
    migrate_through!(migrations, source_version)
    stop_repo!(historical_pid)

    source_pid = start_isolated_repo!(@source, 5)
    facts = Contract.seed_rehearsal_source!(IsolatedMigrationRepo)
    before = Contract.rehearsal_normalized_facts(IsolatedMigrationRepo)
    source_snapshot = Contract.rehearsal_source_snapshot(IsolatedMigrationRepo)
    vacuum_into!(IsolatedMigrationRepo, @target)
    stop_repo!(source_pid)

    target_pid = start_isolated_repo!(@target, 5)
    assert_snapshot!(source_snapshot, Contract.rehearsal_source_snapshot(IsolatedMigrationRepo))
    migrate_through!(migrations, redesign_version)
    :ok = Contract.verify_rehearsal_forward!(IsolatedMigrationRepo, before, facts)

    foreign_keys = singleton!(IsolatedMigrationRepo.query!("PRAGMA foreign_keys").rows)
    foreign_key_check = IsolatedMigrationRepo.query!("PRAGMA foreign_key_check").rows
    helpers = helper_artifacts(IsolatedMigrationRepo)
    stop_repo!(target_pid)

    clear_target!()
    restored_source_pid = start_isolated_repo!(@source, 5)
    vacuum_into!(IsolatedMigrationRepo, @target)
    stop_repo!(restored_source_pid)

    restored_target_pid = start_isolated_repo!(@target, 5)
    restored_snapshot = Contract.rehearsal_source_snapshot(IsolatedMigrationRepo)
    assert_snapshot!(source_snapshot, restored_snapshot)
    stop_repo!(restored_target_pid)

    %{
      status: "ok",
      paths: @allowed,
      source_version: source_version,
      source_construction: %{
        historical_pool_size: 1,
        reopened_pool_size: 5,
        stopped_before_seed: true
      },
      application_repo_started: false,
      forward: %{
        preserved: true,
        foreign_keys: foreign_keys,
        foreign_key_check: foreign_key_check,
        helpers: helpers
      },
      restore: %{exact: true}
    }
  end

  defp require_test_environment! do
    unless Mix.env() == :test, do: raise("rehearsal requires MIX_ENV=test")
  end

  defp reject_arguments! do
    arguments =
      case System.argv() do
        ["--" | rest] -> rest
        arguments -> arguments
      end

    unless arguments == [], do: raise("rehearsal accepts no path arguments")
  end

  defp validate_paths! do
    Enum.each(@allowed, fn path ->
      unless Path.dirname(path) == "/tmp" and
               String.starts_with?(Path.basename(path), "deletion-first-") and
               String.ends_with?(path, ".db") do
        raise "refusing non-disposable path: #{path}"
      end
    end)
  end

  defp start_test_dependencies! do
    {:ok, _apps} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _apps} = Application.ensure_all_started(:ex_unit)
    ExUnit.start(autorun: false)
  end

  defp load_contract! do
    path = Path.expand("../../test/burpee_trainer/deletion_first_migration_test.exs", __DIR__)
    Code.require_file(path)
  end

  defp start_isolated_repo!(database, pool_size) when pool_size in [1, 5] do
    assert_application_repo_stopped!()

    {:ok, pid} =
      IsolatedMigrationRepo.start_link(
        database: database,
        pool_size: pool_size,
        journal_mode: :delete,
        busy_timeout: 10_000,
        stacktrace: true,
        show_sensitive_data_on_connection_error: true
      )

    pid
  end

  defp stop_repo!(pid) do
    GenServer.stop(pid)
    :ok
  end

  defp stop_isolated_repo do
    case Process.whereis(IsolatedMigrationRepo) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp migrate_through!(migrations, version) do
    migrated = Ecto.Migrator.run(IsolatedMigrationRepo, migrations, :up, to: version)

    unless version in migrated or
             IsolatedMigrationRepo.query!(
               "SELECT version FROM schema_migrations WHERE version = ?",
               [version]
             ).rows == [[version]] do
      raise "migration version #{version} was not recorded"
    end
  end

  defp vacuum_into!(repo, destination) when destination in @allowed do
    escaped = String.replace(destination, "'", "''")
    repo.query!("VACUUM INTO '#{escaped}'")
    :ok
  end

  defp assert_snapshot!(expected, actual) do
    unless actual == expected, do: raise("restored snapshot differs from source snapshot")
  end

  defp helper_artifacts(repo) do
    repo.query!("""
    SELECT name FROM sqlite_master
    WHERE name LIKE 'deletion_first_%'
    ORDER BY name
    """).rows
  end

  defp singleton!([[value]]), do: value
  defp singleton!(rows), do: raise("expected one pragma value, got: #{inspect(rows)}")

  defp redesign_version! do
    case Path.wildcard(@redesign_glob) do
      [path] -> migration_version(path)
      paths -> raise "expected one redesign migration, got: #{inspect(paths)}"
    end
  end

  defp migrations! do
    @migration_dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      version = migration_version(path)
      modules = migration_modules(path)
      unless Enum.all?(modules, &Code.ensure_loaded?/1), do: Code.require_file(path)
      Enum.map(modules, &{version, &1})
    end)
  end

  defp migration_version(path) do
    path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
  end

  defp migration_modules(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> then(fn ast ->
      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, acc ->
            {node, [Module.concat(parts) | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(modules)
    end)
  end

  defp clear_target! do
    Enum.each(@sidecars, &remove_allowed!(@target <> &1))
  end

  defp clear_allowed_paths! do
    Enum.each(for(path <- @allowed, suffix <- @sidecars, do: path <> suffix), &remove_allowed!/1)
  end

  defp remove_allowed!(path) do
    allowed_paths = for database <- @allowed, suffix <- @sidecars, do: database <> suffix
    unless path in allowed_paths, do: raise("refusing to remove unmarked path: #{path}")

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "cannot clear disposable path #{path}: #{inspect(reason)}"
    end
  end

  defp assert_application_repo_stopped! do
    if Process.whereis(BurpeeTrainer.Repo), do: raise("application Repo must remain stopped")
  end
end

BurpeeTrainer.DeletionFirstRehearsal.main()
