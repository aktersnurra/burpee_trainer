defmodule BurpeeTrainer.Repo.Migrations.AddExecutionAuthorizationUses do
  use Ecto.Migration

  def up do
    create table(:execution_authorization_uses) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :plan_id, references(:workout_plans, on_delete: :nilify_all)

      add :execution_program_id,
          references(:execution_programs, on_delete: :nilify_all)

      add :authorization_lane, :string, null: false
      add :authorization_source_id, :integer
      add :authorization_fingerprint, :string, null: false
      add :authorization_nonce, :string, null: false
      add :client_session_id, :string, null: false
      add :workout_session_id, references(:workout_sessions, on_delete: :nilify_all)
      add :consumed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:execution_authorization_uses, [:authorization_fingerprint])

    create unique_index(:execution_authorization_uses, [:user_id, :client_session_id])

    create index(:execution_authorization_uses, [:workout_session_id])
    create index(:execution_authorization_uses, [:user_id, :plan_id])
  end

  def down do
    drop index(:execution_authorization_uses, [:user_id, :plan_id])
    drop index(:execution_authorization_uses, [:workout_session_id])
    drop unique_index(:execution_authorization_uses, [:user_id, :client_session_id])
    drop unique_index(:execution_authorization_uses, [:authorization_fingerprint])
    drop table(:execution_authorization_uses)
  end
end
