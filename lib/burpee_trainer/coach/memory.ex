defmodule BurpeeTrainer.Coach.Memory do
  import Ecto.Query
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Coach.{Setting, WorkoutMemory}

  def global_context(user) do
    settings =
      case Repo.get_by(Setting, user_id: user.id) do
        nil -> %{}
        row -> row.settings
      end

    memories =
      Repo.all(
        from m in WorkoutMemory,
          where: m.user_id == ^user.id,
          order_by: [asc: m.id]
      )

    %{
      settings: settings,
      workout_memories:
        Enum.map(memories, fn m ->
          %{
            workout_plan_id: m.workout_plan_id,
            design_session_id: m.design_session_id,
            facts: m.facts,
            workout_reason: m.workout_reason
          }
        end)
    }
  end
end
