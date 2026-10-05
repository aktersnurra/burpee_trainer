defmodule BurpeeTrainer.CoachFirstRehearsal do
  @moduledoc false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E
  @dir Path.expand("../../priv/repo/migrations", __DIR__)
  @version 20_261_005_000_000

  # This automated rehearsal accepts no owner database/backup paths. It creates
  # an upstream fixture and VACUUM copies inside a uniquely owned disposable dir.
  def main do
    unless Mix.env() == :test, do: raise("rehearsal requires MIX_ENV=test")
    unless System.argv() in [[], ["--"]], do: raise("rehearsal accepts no path arguments")
    if Process.whereis(BurpeeTrainer.Repo), do: raise("application Repo must remain stopped")
    config = Application.get_env(:burpee_trainer, BurpeeTrainer.Repo)
    Application.ensure_all_started(:ecto_sqlite3)
    Application.ensure_all_started(:ex_unit)
    ExUnit.start(autorun: false)
    Code.require_file(Path.expand("../../test/burpee_trainer/schema_migration_test.exs", __DIR__))
    migrations = E.migrations(@dir)
    upstream = Enum.filter(migrations, fn {v, _} -> E.upstream?(v) end)
    [{@version, _}] = final = Enum.filter(migrations, fn {v, _} -> v == @version end)
    owned = Path.join(System.tmp_dir!(), "coach-first-rehearsal-#{Ecto.UUID.generate()}")
    File.mkdir!(owned)
    source = Path.join(owned, "source.db")
    target = Path.join(owned, "target.db")
    restored = Path.join(owned, "restored.db")

    try do
      {before, facts} =
        with_repo(source, fn ->
          Ecto.Migrator.run(Repo, upstream, :up, all: true, log: false)
          facts = E.seed_upstream!(Repo)
          before = source_snapshot()
          vacuum!(target)
          {before, facts}
        end)

      with_repo(target, fn ->
        unless source_snapshot() == before, do: raise("copied source differs")
        Ecto.Migrator.run(Repo, final, :up, all: true, log: false)
        :ok = BurpeeTrainer.SchemaMigrationTest.assert_preservation!(Repo, facts)
        [[1]] = Repo.query!("PRAGMA foreign_keys").rows
        [] = Repo.query!("PRAGMA foreign_key_check").rows
        [] = Repo.query!("SELECT name FROM sqlite_temp_master").rows
      end)

      with_repo(source, fn ->
        unless source_snapshot() == before,
          do: raise("source was modified during forward rehearsal")

        vacuum!(restored)
      end)

      with_repo(restored, fn ->
        unless source_snapshot() == before, do: raise("restored snapshot differs")
      end)

      unless Application.get_env(:burpee_trainer, BurpeeTrainer.Repo) == config and
               is_nil(Process.whereis(BurpeeTrainer.Repo)),
             do: raise("application Repo touched")

      IO.puts(
        "COACH_FIRST_REHEARSAL=" <>
          Jason.encode!(%{
            status: "ok",
            owned_directory: owned,
            source: "pinned-master representative fixture",
            target_version: @version,
            forward: %{preserved: true, foreign_keys: 1, foreign_key_check: []},
            restore: %{
              exact: true,
              migration_metadata_preserved: true,
              source_unchanged: true,
              snapshot_sha256:
                :crypto.hash(:sha256, :erlang.term_to_binary(before))
                |> Base.encode16(case: :lower)
            },
            application_repo_started: false
          })
      )
    after
      # Only this invocation's directory can be removed; no caller path accepted.
      File.rm_rf!(owned)
    end
  end

  defp source_snapshot do
    %{
      dump: E.dump(Repo),
      catalog:
        Repo.query!(
          "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name,tbl_name"
        ).rows,
      migration_rows: Repo.query!("SELECT * FROM schema_migrations ORDER BY version").rows
    }
  end

  defp with_repo(path, fun) do
    {:ok, pid} = Repo.start_link(database: path, pool_size: 1, journal_mode: :delete)

    try do
      fun.()
    after
      GenServer.stop(pid)
    end
  end

  defp vacuum!(path), do: Repo.query!("VACUUM INTO ?", [path])
end

BurpeeTrainer.CoachFirstRehearsal.main()
