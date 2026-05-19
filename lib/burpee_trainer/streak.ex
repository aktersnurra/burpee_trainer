defmodule BurpeeTrainer.Streak do
  @moduledoc """
  Computes streak state from session history. Reads from DB, updates
  user_stats with previous_best, returns a %State{} struct.

  Week boundary: Monday 00:00 – Sunday 23:59:59 UTC (ISO 8601).
  A week counts toward the streak iff total session minutes >= 80.
  The current open week never breaks or extends the streak count.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Repo

  @goal_min 80

  defmodule State do
    @moduledoc "Snapshot of the user's streak state."

    @type t :: %__MODULE__{
            current_week_minutes: number(),
            current_week_target: pos_integer(),
            days_active_this_week: [Date.t()],
            on_pace?: boolean(),
            streak_weeks: non_neg_integer(),
            previous_best_weeks: non_neg_integer(),
            previous_best_ended_on: Date.t() | nil
          }

    defstruct current_week_minutes: 0,
              current_week_target: 80,
              days_active_this_week: [],
              on_pace?: false,
              streak_weeks: 0,
              previous_best_weeks: 0,
              previous_best_ended_on: nil
  end

  @spec compute(User.t(), Date.t()) :: State.t()
  def compute(%User{id: user_id}, today) do
    week_start = Date.beginning_of_week(today, :monday)
    sessions = fetch_sessions(user_id)

    by_week =
      Enum.group_by(sessions, fn %{date: d} ->
        Date.beginning_of_week(d, :monday)
      end)

    current_week_sessions = Map.get(by_week, week_start, [])
    current_week_minutes = Enum.sum(Enum.map(current_week_sessions, & &1.duration_min))

    days_active =
      current_week_sessions
      |> Enum.map(& &1.date)
      |> Enum.uniq()

    days_elapsed = Date.day_of_week(today, :monday)
    on_pace? = current_week_minutes >= @goal_min * days_elapsed / 7

    # Walk backwards week-by-week from the most recent complete week.
    # Weeks with no sessions count as 0 minutes and break the streak.
    streak = count_streak(Date.add(week_start, -7), by_week)

    user_stats = get_or_init_user_stats(user_id)
    stored_best = user_stats.previous_best_weeks
    stored_ended = user_stats.previous_best_ended_on

    # Compute the all-time best streak from full session history.
    all_time_best = max_historical_streak(by_week, week_start)

    {new_best, new_ended} =
      cond do
        all_time_best > stored_best -> {all_time_best, today}
        true -> {stored_best, stored_ended}
      end

    if new_best != stored_best, do: upsert_user_stats(user_id, new_best, new_ended)

    %State{
      current_week_minutes: current_week_minutes,
      current_week_target: @goal_min,
      days_active_this_week: days_active,
      on_pace?: on_pace?,
      streak_weeks: streak,
      previous_best_weeks: new_best,
      previous_best_ended_on: new_ended
    }
  end

  # Find the all-time maximum consecutive streak across all prior complete weeks.
  defp max_historical_streak(by_week, current_week_start) do
    prior_weeks =
      by_week
      |> Map.keys()
      |> Enum.reject(&(Date.compare(&1, current_week_start) != :lt))
      |> Enum.sort(Date)

    case prior_weeks do
      [] ->
        0

      [first | _] ->
        last = List.last(prior_weeks)

        # Walk every week from first to last, tracking runs
        Stream.iterate(first, &Date.add(&1, 7))
        |> Stream.take_while(fn w -> Date.compare(w, last) != :gt end)
        |> Enum.reduce({0, 0}, fn week, {max_so_far, run} ->
          minutes = week_minutes(by_week, week)

          if minutes >= @goal_min do
            new_run = run + 1
            {max(max_so_far, new_run), new_run}
          else
            {max_so_far, 0}
          end
        end)
        |> elem(0)
    end
  end

  defp week_minutes(by_week, week) do
    by_week
    |> Map.get(week, [])
    |> then(fn sessions -> Enum.sum(Enum.map(sessions, & &1.duration_min)) end)
  end

  # Walk backwards week-by-week. Stop as soon as a week has < @goal_min minutes.
  defp count_streak(week, by_week, acc \\ 0) do
    sessions = Map.get(by_week, week, [])
    minutes = Enum.sum(Enum.map(sessions, & &1.duration_min))

    if minutes >= @goal_min do
      count_streak(Date.add(week, -7), by_week, acc + 1)
    else
      acc
    end
  end

  defp fetch_sessions(user_id) do
    Repo.all(
      from s in BurpeeTrainer.Workouts.WorkoutSession,
        where: s.user_id == ^user_id,
        select: %{
          date: fragment("date(?)", s.inserted_at),
          duration_min: s.duration_sec_actual / 60.0
        }
    )
    |> Enum.map(fn %{date: d, duration_min: m} ->
      %{date: Date.from_iso8601!(d), duration_min: m}
    end)
  end

  defp get_or_init_user_stats(user_id) do
    case Repo.one(
           from us in "user_stats",
             where: us.user_id == ^user_id,
             select: %{
               previous_best_weeks: us.previous_best_weeks,
               previous_best_ended_on: us.previous_best_ended_on
             }
         ) do
      nil -> %{previous_best_weeks: 0, previous_best_ended_on: nil}
      row -> row
    end
  end

  defp upsert_user_stats(user_id, best_weeks, ended_on) do
    ended_str = if ended_on, do: Date.to_iso8601(ended_on)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Repo.insert_all(
      "user_stats",
      [
        %{
          user_id: user_id,
          previous_best_weeks: best_weeks,
          previous_best_ended_on: ended_str,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:previous_best_weeks, :previous_best_ended_on, :updated_at]},
      conflict_target: :user_id
    )
  end
end
