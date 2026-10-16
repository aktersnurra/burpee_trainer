defmodule BurpeeTrainer.Repo.Migrations.CreateLlmCalls do
  use Ecto.Migration

  def change do
    create table(:llm_calls) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :purpose, :string, null: false
      add :run_id, :string, null: false
      add :model, :string, null: false
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :cost_usd, :float
      add :reserved_cost_usd, :float, null: false, default: 0.0
      add :outcome, :string, null: false
      add :duration_ms, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:llm_calls, [:user_id, :inserted_at])
    create index(:llm_calls, [:run_id])
  end
end
