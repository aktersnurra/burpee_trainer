defmodule BurpeeTrainer.Coach.Learning do
  @moduledoc """
  Boundary for recording coach learning side effects after completed sessions.

  `record_session_completed/2` returns `:ok` after scheduling or running the update.
  In async mode, update failures crash only the supervised task, not the caller.
  """

  require Logger

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Workouts.WorkoutSession

  @supervisor BurpeeTrainer.CoachLearningSupervisor

  @spec record_session_completed(User.t(), WorkoutSession.t()) :: :ok
  def record_session_completed(%User{} = user, %WorkoutSession{} = session) do
    if sync?() do
      update_arms(user, session)
    else
      start_update_task(user, session)
    end

    :ok
  end

  defp sync? do
    Application.get_env(:burpee_trainer, :coach_learning_mode, :async) == :sync
  end

  defp start_update_task(user, session) do
    case Task.Supervisor.start_child(@supervisor, fn -> update_arms(user, session) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not start coach learning task: #{inspect(reason)}")
        :ok
    end
  end

  defp update_arms(user, session) do
    :telemetry.execute([:burpee_trainer, :coach, :learning, :start], %{}, %{
      pid: self(),
      user_id: user.id,
      session_id: session.id
    })

    case Coach.update_arms(user, session) do
      :ok ->
        :ok

      other ->
        Logger.warning("Coach learning update returned unexpected result: #{inspect(other)}")
        :ok
    end
  end
end
