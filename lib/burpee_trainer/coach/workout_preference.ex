defmodule BurpeeTrainer.Coach.WorkoutPreference do
  @moduledoc """
  What the athlete said about a particular saved workout when they finished it: do it again,
  or avoid it. The latest answer for a workout counts, a later session without an answer
  changes nothing, and an answer lapses after four weeks so a workout is never banished for good.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts

  @window_days 28

  @type t :: %{pos_integer() => :avoid | :choose_again}

  @spec for_scope(Scope.t()) :: t()
  def for_scope(%Scope{} = scope), do: decide(Workouts.list_sessions(scope), DateTime.utc_now())

  @spec decide([map()], DateTime.t()) :: t()
  def decide(sessions, now) do
    since = DateTime.add(now, -@window_days, :day)

    sessions
    |> Enum.filter(
      &(is_integer(&1.plan_id) and &1.preference_feedback in [:avoid, :choose_again])
    )
    |> Enum.sort_by(&{DateTime.to_unix(&1.completed_at, :microsecond), &1.id}, :desc)
    |> Enum.uniq_by(& &1.plan_id)
    |> Enum.filter(&(DateTime.compare(&1.completed_at, since) != :lt))
    |> Map.new(&{&1.plan_id, &1.preference_feedback})
  end
end
