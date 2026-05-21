defmodule BurpeeTrainer.Repo.Migrations.CreateCoachArms do
  use Ecto.Migration

  def change do
    create table(:coach_arms) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :burpee_type, :string, null: false
      add :dimension, :string, null: false
      add :step, :float, null: false
      add :alpha, :float, null: false, default: 1.0
      add :beta, :float, null: false, default: 1.0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_arms, [:user_id, :burpee_type, :dimension, :step])
    create index(:coach_arms, [:user_id, :burpee_type])
  end
end
