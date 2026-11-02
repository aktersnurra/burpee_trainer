defmodule BurpeeTrainer.Coach.WeekStartJob do
  @moduledoc """
  At the start of each owner's local week, the coach ranks the week's first workout afresh
  from their history and goals, so Home has it ready when they open the app. Runs from cron
  once, at Monday 00:00 UTC; each slot is planned at most once
  (`PlanNextWorkoutJob.admit_once/2`).
  """
  use Oban.Worker, queue: :coach, max_attempts: 1

  require Logger
  alias BurpeeTrainer.{Accounts, Coach, UserTime}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{PlanNextWorkoutJob, Policy}

  @impl true
  def perform(%Oban.Job{}), do: plan_due(DateTime.utc_now(:second))

  @doc "Admits planning for every owner whose local week started today and who still needs a workout."
  @spec plan_due(DateTime.t()) :: :ok
  def plan_due(%DateTime{} = now) do
    for user <- Accounts.list_users(),
        scope = Scope.for_user(user),
        Coach.enabled?(scope),
        {:ok, slot} <- [due_slot(scope, now)] do
      with {:error, reason} <- PlanNextWorkoutJob.admit_once(scope, slot) do
        Logger.warning(
          "week_start_plan_not_admitted user_id=#{user.id} reason=#{inspect(reason)}"
        )
      end
    end

    :ok
  end

  defp due_slot(%Scope{user: user} = scope, now) do
    with {:ok, %{date: date, week_start: date}} <- UserTime.context(user, now),
         {:ok, %{home_state: :workout_needed} = slot} <- Policy.required_slot(scope, now) do
      {:ok, slot}
    else
      _ -> :none
    end
  end
end
