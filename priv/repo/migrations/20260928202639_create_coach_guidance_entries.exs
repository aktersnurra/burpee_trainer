defmodule BurpeeTrainer.Repo.Migrations.CreateCoachGuidanceEntries do
  use Ecto.Migration

  def change do
    create table(:coach_guidance_entries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :kind, :string, null: false, default: "pending"
      add :summary, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:coach_guidance_entries, [:user_id, :id])
  end
end
