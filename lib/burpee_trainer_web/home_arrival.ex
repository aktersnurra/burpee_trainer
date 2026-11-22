defmodule BurpeeTrainerWeb.HomeArrival do
  @moduledoc """
  Home arriving from a save. The runner and a video return to `/?saved=<id>`, and Home shows the
  week bar filling from where it stood before that session and the session's ✓ arriving; a save
  that brought the week to its target lights that week's flame the first time Progress opens.
  Only the owner's own session, completed this week, arrives; anything else is an ordinary Home.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{WeekWindow, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  @enforce_keys [:completed_at, :before_sec, :target_met?, :week_start]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          completed_at: DateTime.t(),
          before_sec: non_neg_integer(),
          target_met?: boolean(),
          week_start: Date.t()
        }

  @doc "The arrival for `saved` (the query's session id) against this week's `slot`, or nil."
  @spec from_save(Scope.t(), map() | nil, String.t()) :: t() | nil
  def from_save(
        %Scope{} = scope,
        %{completed_sec: done, weekly_target_sec: target, week_start: week_start},
        saved
      )
      when is_binary(saved) do
    with {id, ""} <- Integer.parse(saved),
         %WorkoutSession{state: :completed, completed_at: %DateTime{} = at} = session <-
           Workouts.get_session(scope, id),
         true <- DateTime.compare(at, WeekWindow.week_start_utc(scope)) != :lt do
      before = max(done - Policy.credited_duration(session), 0)

      %__MODULE__{
        completed_at: at,
        before_sec: before,
        target_met?: before < target and done >= target,
        week_start: week_start
      }
    else
      _ -> nil
    end
  end

  def from_save(%Scope{}, _slot, _saved), do: nil
end
