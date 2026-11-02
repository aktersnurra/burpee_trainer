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

  # Migration tests compare schemas through this normalizer; it must not hide real changes.
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

  defp sql(columns), do: ~s|CREATE TABLE "users" (| <> Enum.join(columns, ", ") <> ")"
end
