defmodule BurpeeTrainer.MigrationSchemaNormalizationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E

  @columns [
    ~s|"id" INTEGER PRIMARY KEY AUTOINCREMENT|,
    ~s|"username" TEXT COLLATE BINARY NOT NULL UNIQUE|,
    ~s|"timezone" TEXT DEFAULT 'Etc/UTC' NOT NULL|,
    ~s|"parent_id" INTEGER REFERENCES users(id) ON DELETE SET NULL|,
    ~s|CONSTRAINT name_check CHECK (length(username) > 0 AND username <> 'a,b)')|
  ]

  test "only full users column order is ignored, even with nested/quoted commas" do
    assert E.normalize_users_sql(sql(@columns)) ==
             E.normalize_users_sql(sql(Enum.reverse(@columns)))
  end

  test "whole dumps compare equal after pure users column reordering" do
    run = fn columns ->
      E.with_db(fn repo ->
        repo.query!(sql(columns))

        repo.query!(
          "CREATE INDEX users_timezone_username ON users (timezone, username COLLATE BINARY DESC)"
        )

        repo.query!("INSERT INTO users (username, timezone) VALUES ('seed', 'Etc/UTC')")
        E.dump(repo)
      end)
    end

    {columns, constraints} = Enum.split(@columns, 4)
    assert run.(@columns) == run.(Enum.reverse(columns) ++ constraints)
  end

  test "type, nullability, default, PK, check, FK, unique, collation, autoincrement and suffix changes differ" do
    original = sql(@columns)

    for {before, after_text} <- [
          {"username\" TEXT", "username\" BLOB"},
          {"NOT NULL UNIQUE", "UNIQUE"},
          {"'Etc/UTC'", "'Europe/Stockholm'"},
          {"PRIMARY KEY", "UNIQUE"},
          {"length(username) > 0", "length(username) > 2"},
          {"ON DELETE SET NULL", "ON DELETE CASCADE"},
          {"NOT NULL UNIQUE", "NOT NULL"},
          {"COLLATE BINARY", "COLLATE NOCASE"},
          {" AUTOINCREMENT", ""}
        ] do
      changed = String.replace(original, before, after_text)
      assert changed != original
      refute E.normalize_users_sql(original) == E.normalize_users_sql(changed)
    end

    refute E.normalize_users_sql(original) == E.normalize_users_sql(original <> " STRICT")
  end

  test "users unique indexes and index key order remain in whole schema comparison" do
    E.with_db(fn repo ->
      repo.query!(sql(@columns))

      repo.query!(
        "CREATE UNIQUE INDEX users_pair ON users (username COLLATE NOCASE, timezone DESC)"
      )

      before = E.dump(repo)
      repo.query!("DROP INDEX users_pair")
      repo.query!("CREATE INDEX users_pair ON users (timezone DESC, username COLLATE BINARY)")
      refute E.dump(repo).schema == before.schema
    end)
  end

  defp sql(columns), do: ~s|CREATE TABLE "users" (| <> Enum.join(columns, ", ") <> ")"
end
