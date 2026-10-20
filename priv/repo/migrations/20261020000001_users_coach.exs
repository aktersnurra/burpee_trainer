defmodule BurpeeTrainer.Repo.Migrations.UsersCoach do
  @moduledoc """
  Who coaches the user, `app` (the app's own model) or `claude` (through MCP), replaces
  the `coach_enabled` flag; each user keeps the coach they had.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :coach, :string, null: false, default: "app"
    end

    execute "UPDATE users SET coach = CASE WHEN coach_enabled THEN 'app' ELSE 'claude' END"

    alter table(:users) do
      remove :coach_enabled
    end
  end

  def down do
    alter table(:users) do
      add :coach_enabled, :boolean, null: false, default: true
    end

    execute "UPDATE users SET coach_enabled = (coach = 'app')"

    alter table(:users) do
      remove :coach
    end
  end
end
