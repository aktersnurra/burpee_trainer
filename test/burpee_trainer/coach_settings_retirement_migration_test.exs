defmodule BurpeeTrainer.CoachSettingsRetirementMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E

  @migrations Path.expand("../../priv/repo/migrations", __DIR__)

  test "the unused coach_settings table is gone after migrating" do
    E.with_db(fn repo ->
      Ecto.Migrator.run(repo, E.migrations(@migrations), :up, all: true, log: false)

      assert repo.query!("SELECT name FROM sqlite_master WHERE tbl_name = 'coach_settings'").rows ==
               []

      assert repo.query!("PRAGMA foreign_key_check").rows == []
    end)
  end
end
