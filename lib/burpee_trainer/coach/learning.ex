defmodule BurpeeTrainer.Coach.Learning do
  @moduledoc """
  Boundary for recording coach learning side effects after completed sessions.
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
    Application.get_env(:burpee_trainer, :coach_learning_mode, default_mode()) == :sync
  end

  defp default_mode do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      :sync
    else
      :async
    end
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
    case Coach.update_arms(user, session) do
      :ok ->
        :ok

      other ->
        Logger.warning("Coach learning update returned unexpected result: #{inspect(other)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Coach learning update failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  end
end
