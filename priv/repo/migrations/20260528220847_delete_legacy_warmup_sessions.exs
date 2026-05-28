defmodule BurpeeTrainer.Repo.Migrations.DeleteLegacyWarmupSessions do
  use Ecto.Migration

  def up do
    execute("DELETE FROM workout_sessions WHERE tags = 'warmup'")
  end

  def down do
    :ok
  end
end
