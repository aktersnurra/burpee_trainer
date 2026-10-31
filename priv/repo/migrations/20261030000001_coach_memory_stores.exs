defmodule BurpeeTrainer.Repo.Migrations.CoachMemoryStores do
  use Ecto.Migration

  # The coach's memory as two bounded stores, as in the Hermes agent: `user` (who the athlete
  # is) and `memory` (the coach's notes on coaching them). Every note so far is about the
  # athlete. A patched entry points at the one it replaced, so the change reads as one line.
  def change do
    alter table(:coach_notes) do
      add :store, :string, null: false, default: "user"
      add :supersedes_id, :integer
    end

    create index(:coach_notes, [:user_id, :store])
  end
end
