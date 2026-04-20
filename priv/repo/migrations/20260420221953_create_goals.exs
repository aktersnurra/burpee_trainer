defmodule BurpeeTrainer.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    create table(:goals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :burpee_type, :string, null: false
      add :burpee_count_target, :integer, null: false
      add :duration_sec_target, :integer, null: false
      add :date_target, :date, null: false
      add :burpee_count_baseline, :integer, null: false
      add :duration_sec_baseline, :integer, null: false
      add :date_baseline, :date, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:goals, [:user_id])
    create index(:goals, [:user_id, :burpee_type])

    # Partial unique index: at most one active goal per (user_id, burpee_type).
    create unique_index(:goals, [:user_id, :burpee_type],
             where: "status = 'active'",
             name: :goals_active_user_type_index
           )
  end
end
