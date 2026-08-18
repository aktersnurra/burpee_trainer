defmodule BurpeeTrainer.Repo.Migrations.AddCoachValidationProvenanceAndTimezoneProvisioning do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :timezone_provisioned, :boolean, null: false, default: false
    end

    alter table(:coach_recommendations) do
      add :validation_status, :string
      add :execution_program_id, references(:execution_programs)
      add :execution_program_hash, :string
    end

    create index(:coach_recommendations, [:execution_program_id])

    alter table(:coach_workout_drafts) do
      add :validation_status, :string
      add :execution_program_id, references(:execution_programs)
      add :execution_program_hash, :string
    end

    create index(:coach_workout_drafts, [:execution_program_id])
  end
end
