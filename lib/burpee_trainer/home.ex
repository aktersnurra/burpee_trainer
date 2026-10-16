defmodule BurpeeTrainer.Home do
  @moduledoc "Home's decision: load facts once, derive one state purely."

  alias BurpeeTrainer.{History, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Home.{Facts, State}

  @spec facts(Scope.t(), DateTime.t()) :: {:ok, Facts.t()} | {:error, :invalid_timezone}
  def facts(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, slot} <- slot(scope, now) do
      started_session = Workouts.current_started_session(scope)
      selection = ensure_selection(scope, slot, started_session)

      with {:ok, results} <- History.results(scope, now) do
        {:ok,
         %Facts{
           slot: slot,
           started_session: started_session,
           selection: selection,
           results: results
         }}
      else
        {:error, _reason} -> {:error, :invalid_timezone}
      end
    end
  end

  @spec state(Facts.t()) :: State.t()
  defdelegate state(facts), to: State, as: :derive

  defp ensure_selection(scope, %{home_state: :workout_needed} = slot, nil) do
    case Workouts.current_home_selection(scope, slot) do
      nil -> selection(scope, slot)
      current -> current
    end
  end

  defp ensure_selection(_scope, _slot, _started_session), do: nil

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
