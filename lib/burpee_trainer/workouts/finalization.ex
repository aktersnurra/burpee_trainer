defmodule BurpeeTrainer.Workouts.Finalization do
  alias BurpeeTrainer.Repo

  def deliver({:ok, {value, nil}}), do: {:ok, value}

  def deliver({:ok, {value, plan}}) do
    notify(plan)
    {:ok, value}
  end

  def deliver({:error, _} = error), do: error

  def notify(plan) do
    unless Repo.in_transaction?() do
      Phoenix.PubSub.broadcast(
        BurpeeTrainer.PubSub,
        "workout_finalized",
        {:workout_finalized,
         %{
           user_id: plan.user_id,
           workout_plan_id: plan.id,
           design_session_id: Map.get(plan, :design_session_id)
         }}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
