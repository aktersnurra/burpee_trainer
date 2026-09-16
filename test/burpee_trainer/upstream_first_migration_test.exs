defmodule BurpeeTrainer.UpstreamFirstMigrationTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo

  @migration_dir Path.expand("../../priv/repo/migrations", __DIR__)
  # A database deployed from master@origin before this branch: every migration
  # up to the upstream pose-trace digest, plus the upstream OIDC migration.
  @upstream_last_shared 20_260_817_230_052
  @upstream_oidc 20_260_908_000_000
  @branch_only_before_shared 20_260_804_220_023

  test "a database that already applied upstream OIDC migrates to the branch schema" do
    with_isolated_repo(fn repo, migrations ->
      {upstream, branch} =
        Enum.split_with(migrations, fn {version, _module} ->
          (version <= @upstream_last_shared and version != @branch_only_before_shared) or
            version == @upstream_oidc
        end)

      Ecto.Migrator.run(repo, upstream, :up, all: true, log: false)
      assert column_names(repo, "users") |> Enum.member?("oidc_sub")
      refute column_names(repo, "users") |> Enum.member?("password_hash")

      repo.query!(
        "INSERT INTO users (username, oidc_sub, inserted_at, updated_at) VALUES ('upstream', 'sub-1', '2026-09-20T00:00:00Z', '2026-09-20T00:00:00Z')"
      )

      Ecto.Migrator.run(repo, branch, :up, all: true, log: false)

      applied = repo.query!("SELECT version FROM schema_migrations").rows |> List.flatten()
      assert Enum.sort(applied) == Enum.sort(Enum.map(migrations, &elem(&1, 0)))
      assert repo.query!("SELECT username, oidc_sub FROM users").rows == [["upstream", "sub-1"]]
      assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      assert repo.query!("PRAGMA foreign_key_check").rows == []

      assert repo.query!(
               "SELECT COUNT(*) FROM workout_plans WHERE origin = 'built_in' AND state = 'published'"
             ).rows == [[1]]
    end)
  end

  defp column_names(repo, table),
    do: repo.query!("PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1))

  defp with_isolated_repo(fun) do
    database_path =
      Path.join(
        System.tmp_dir!(),
        "upstream-first-migration-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    Application.put_env(:burpee_trainer, IsolatedMigrationRepo,
      database: database_path,
      pool_size: 1,
      journal_mode: :wal,
      busy_timeout: 10_000
    )

    try do
      migrations = migrations()

      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(IsolatedMigrationRepo, &fun.(&1, migrations),
                 mode: :temporary,
                 pool_size: 1
               )
    after
      Application.delete_env(:burpee_trainer, IsolatedMigrationRepo)
      for suffix <- ["", "-shm", "-wal"], do: File.rm(database_path <> suffix)
    end
  end

  defp migrations do
    @migration_dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      version =
        path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()

      Enum.map(loaded_or_required(path), &{version, &1})
    end)
  end

  defp loaded_or_required(path) do
    {_ast, modules} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    modules = Enum.reverse(modules)
    unless Enum.all?(modules, &Code.ensure_loaded?/1), do: Code.require_file(path)
    modules
  end
end
