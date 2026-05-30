defmodule BurpeeTrainer.Milestones do
  @moduledoc """
  Pure milestone detection. No Ecto, no side effects.

  Given a snapshot of the user's state immediately before and after a session
  was saved (plus their stored personal bests), returns an ordered list of the
  celebration-worthy things that just happened. The caller (the `Workouts`
  context) is responsible for gathering the inputs and persisting any new
  bests; this module only decides *what* to celebrate.

  Each event is a map `%{type: atom, value: term}`. Events are returned in
  descending order of significance so the UI can present the headline first.
  """

  alias BurpeeTrainer.Levels

  # Cumulative push-up landmarks worth a callout.
  @lifetime_milestones [1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]
  # A gap of at least this many days since the last session of this type is a
  # "welcome back".
  @comeback_days 10

  # Higher = shown first in the celebration overlay.
  @priority %{
    level_up: 100,
    goal_reached: 90,
    week_pushup_pr: 80,
    lifetime_milestone: 70,
    session_pushup_pr: 60,
    pace_pr: 50,
    balanced_week: 40,
    comeback: 30
  }

  @type event :: %{type: atom, value: term}

  @doc """
  Detect milestones from a pre/post snapshot. See module doc for the shape.
  Keys with no relevant change simply produce no event.
  """
  @spec detect(map) :: [event]
  def detect(input) do
    [
      level_up(input),
      goal_reached(input),
      week_pushup_pr(input),
      lifetime_milestone(input),
      session_pushup_pr(input),
      pace_pr(input),
      balanced_week(input),
      comeback(input)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn %{type: t} -> -Map.fetch!(@priority, t) end)
  end

  @doc "Lifetime push-up thresholds, ascending."
  @spec lifetime_milestones() :: [pos_integer]
  def lifetime_milestones, do: @lifetime_milestones

  @doc "Minimum day gap that counts as a comeback."
  @spec comeback_days() :: pos_integer
  def comeback_days, do: @comeback_days

  # ---------------------------------------------------------------------------
  # Individual detectors — each returns an event map or nil
  # ---------------------------------------------------------------------------

  defp level_up(%{level_before: before, level_after: after_}) do
    if higher?(after_, before),
      do: %{type: :level_up, value: %{from: before, to: after_}}
  end

  defp level_up(_), do: nil

  # Crossover only: fires the single time the week's running total passes the
  # stored best, not on every session afterwards.
  defp week_pushup_pr(%{
         week_pushups_before: before,
         week_pushups_after: after_,
         best_week_pushups_before: best
       })
       when is_integer(before) and is_integer(after_) and is_integer(best) do
    if before <= best and after_ > best and after_ > 0,
      do: %{type: :week_pushup_pr, value: after_}
  end

  defp week_pushup_pr(_), do: nil

  defp session_pushup_pr(%{
         session_pushups: pushups,
         best_session_pushups_before: best
       })
       when is_integer(pushups) and is_integer(best) do
    if pushups > best and pushups > 0,
      do: %{type: :session_pushup_pr, value: pushups}
  end

  defp session_pushup_pr(_), do: nil

  defp pace_pr(%{
         session_qualifies_pace?: true,
         session_pace: pace,
         best_pace_before: best
       })
       when is_number(pace) and pace > 0 do
    if is_nil(best) or pace < best,
      do: %{type: :pace_pr, value: pace}
  end

  defp pace_pr(_), do: nil

  defp lifetime_milestone(%{
         lifetime_after: after_,
         lifetime_milestone_before: prior
       })
       when is_integer(after_) and is_integer(prior) do
    @lifetime_milestones
    |> Enum.filter(&(&1 > prior and &1 <= after_))
    |> case do
      [] -> nil
      crossed -> %{type: :lifetime_milestone, value: Enum.max(crossed)}
    end
  end

  defp lifetime_milestone(_), do: nil

  # Crossover only: the week just became balanced.
  defp balanced_week(%{balanced_before?: false, balanced_after?: true}),
    do: %{type: :balanced_week, value: true}

  defp balanced_week(_), do: nil

  defp goal_reached(%{goal: %{deadline: deadline} = goal})
       when deadline in [:early, :on_time, :late],
       do: %{type: :goal_reached, value: goal}

  defp goal_reached(_), do: nil

  defp comeback(%{days_since_last: days}) when is_integer(days) and days >= @comeback_days,
    do: %{type: :comeback, value: days}

  defp comeback(_), do: nil

  # Lower index in the highest→lowest level list = higher level.
  defp higher?(a, b) do
    levels = Levels.all_levels()
    rank = fn l -> Enum.find_index(levels, &(&1 == l)) end

    case {rank.(a), rank.(b)} do
      {ra, rb} when is_integer(ra) and is_integer(rb) -> ra < rb
      _ -> false
    end
  end
end
