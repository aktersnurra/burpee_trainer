defmodule BurpeeTrainer.Repo.Migrations.DropCoachSettings do
  use Ecto.Migration

  # Coach.Setting was removed; nothing reads or writes these rows any more.
  def up, do: drop(table(:coach_settings))

  def down do
    create table(:coach_settings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :settings, :text, null: false, default: "{}"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_settings, [:user_id])
  end
end
