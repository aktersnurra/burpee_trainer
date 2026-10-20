defmodule BurpeeTrainer.Repo.Migrations.TwentyMinuteGoals do
  @moduledoc """
  A goal is reps in one 20-minute session. Open goals keep their reps and become 20-minute
  goals; achieved and abandoned goals are history and keep the duration they had.
  """
  use Ecto.Migration

  def up do
    execute("UPDATE goals SET duration_sec_target = 1200 WHERE status IN ('active', 'proposed')")
  end

  # The old durations are not kept; the goals stay 20-minute goals.
  def down, do: :ok
end
