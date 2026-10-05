defmodule BurpeeTrainer.Home do
  @moduledoc "Home's decision: load facts once, derive one state purely."

  import Ecto.Query

  alias BurpeeTrainer.{History, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Home.{Facts, State}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  @spec facts(Scope.t(), DateTime.t()) :: {:ok, Facts.t()} | {:error, :invalid_timezone}
  def facts(%Scope{user: user}, %DateTime{} = now) do
    with {:ok, slot} <- slot(user, now) do
      started_session = Workouts.current_started_session(user)

      history? =
        Repo.exists?(
          from(session in WorkoutSession,
            where: session.user_id == ^user.id and session.state == :completed
          )
        )

      owned_plan? =
        Repo.exists?(
          from(plan in WorkoutPlan,
            where: plan.user_id == ^user.id and plan.state == :published
          )
        )

      selection = ensure_selection(user, slot, started_session, history?, owned_plan?)

      with {:ok, results} <- History.results(user, now) do
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

  defp ensure_selection(user, %{home_state: :workout_needed} = slot, nil, true, _owned_plan?) do
    selection(user, slot)
  end

  defp ensure_selection(user, %{home_state: :workout_needed} = slot, nil, _history?, true) do
    selection(user, slot)
  end

  defp ensure_selection(_user, _slot, _started_session, _history?, _owned_plan?), do: nil

  defp selection(user, slot) do
    case Workouts.ensure_home_selection(user, slot) do
      {:ok, selection} -> selection
      {:error, _reason} -> nil
    end
  end

  defp slot(user, now) do
    case Policy.required_slot(user, now) do
      {:ok, slot} -> {:ok, slot}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end
end
