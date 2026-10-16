defmodule BurpeeTrainer.Repo.Migrations.CreateCoachNotebooks do
  use Ecto.Migration

  def change do
    create table(:coach_notebooks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false, default: ""
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_notebooks, [:user_id])
  end
end
