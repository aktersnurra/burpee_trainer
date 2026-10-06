defmodule BurpeeTrainer.Home do
  @moduledoc "Home's decision: load facts once, derive one state purely."

  import Ecto.Query

  alias BurpeeTrainer.{History, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Home.{Facts, State}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}

  @spec facts(Scope.t(), DateTime.t()) :: {:ok, Facts.t()} | {:error, :invalid_timezone}
  def facts(%Scope{user: user} = scope, %DateTime{} = now) do
    with {:ok, slot} <- slot(scope, now) do
      started_session = Workouts.current_started_session(scope)

      history? =
        Repo.exists?(from(session in WorkoutSession, where: session.user_id == ^user.id)) or
          Repo.exists?(
            from(recommendation in CoachRecommendation, where: recommendation.user_id == ^user.id)
          )

      owned_plan? =
        Repo.exists?(
          from(plan in WorkoutPlan,
            where: plan.user_id == ^user.id
          )
        )

      selection = ensure_selection(scope, slot, started_session, history?, owned_plan?)

      with {:ok, results} <- History.results(scope, now) do
        {:ok,
         %Facts{
           slot: slot,
           started_session: started_session,
           selection: selection,
           history?: history?,
           owned_plan?: owned_plan?,
           results: results
         }}
      else
        {:error, _reason} -> {:error, :invalid_timezone}
      end
    end
  end

  @spec state(Facts.t()) :: State.t()
  defdelegate state(facts), to: State, as: :derive

  defp ensure_selection(scope, %{home_state: :workout_needed} = slot, nil, history?, owned_plan?) do
    case Workouts.current_home_selection(scope, slot) do
      nil when history? or owned_plan? -> selection(scope, slot)
      current -> current
    end
  end

  defp ensure_selection(_user, _slot, _started_session, _history?, _owned_plan?), do: nil

  defp selection(scope, slot) do
    case Workouts.ensure_home_selection(scope, slot) do
      {:ok, selection} -> selection
      {:error, _reason} -> nil
    end
  end

  defp slot(scope, now) do
    case Policy.required_slot(scope, now) do
      {:ok, slot} -> {:ok, slot}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end
end
