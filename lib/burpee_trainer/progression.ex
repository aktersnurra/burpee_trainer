defmodule BurpeeTrainer.Progression do
  @moduledoc """
  Pure functional progression engine. Takes a `%Goal{}` and a list of
  recent `%WorkoutSession{}` structs and returns a `%Recommendation{}`.

  Periodization: 3 weeks build + 1 week deload, cycling.

  - build_1: 0.90× the linearly-interpolated target
  - build_2: 1.00×
  - build_3: 1.05×
  - deload:  0.80×

  Trend monitoring uses least-squares on the last 4 matching-type
  sessions, implemented in pure Elixir.
  """

  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Workouts.WorkoutSession

  @phase_multipliers %{build_1: 0.90, build_2: 1.00, build_3: 1.05, deload: 0.80}
  @behind_boost 0.05
  @trend_threshold 0.10
  @consistency_window_days 14
  @consistency_sessions_min 2
  @trend_sessions_min 2
  @trend_sessions_window 4
  @volume_sec_weekly_target 80 * 60

  defmodule Recommendation do
    @moduledoc """
    Output of `Progression.recommend/3`.

    `phase` is one of `:build_1 | :build_2 | :build_3 | :deload`.
    `trend_status` is one of `:ahead | :on_track | :behind | :low_consistency`.
    """

    @enforce_keys [
      :goal_id,
      :burpee_type,
      :phase,
      :trend_status,
      :burpee_count_suggested,
      :duration_sec_suggested,
      :sec_per_rep_suggested,
      :rationale,
      :weeks_remaining,
      :burpee_count_projected_at_goal
    ]
    defstruct [
      :goal_id,
      :burpee_type,
      :phase,
      :trend_status,
      :burpee_count_suggested,
      :duration_sec_suggested,
      :sec_per_rep_suggested,
      :rationale,
      :weeks_remaining,
      :burpee_count_projected_at_goal
    ]

    @type t :: %__MODULE__{
            goal_id: term,
            burpee_type: atom,
            phase: :build_1 | :build_2 | :build_3 | :deload,
            trend_status: :ahead | :on_track | :behind | :low_consistency,
            burpee_count_suggested: integer,
            duration_sec_suggested: integer,
            sec_per_rep_suggested: float,
            rationale: String.t(),
            weeks_remaining: integer,
            burpee_count_projected_at_goal: number | nil
          }
  end

  @doc """
  Produce a recommendation for the next session based on the goal and
  recent sessions. `today` defaults to `Date.utc_today/0`.
  """
  @spec recommend(Goal.t(), [WorkoutSession.t()]) :: Recommendation.t()
  @spec recommend(Goal.t(), [WorkoutSession.t()], Date.t()) :: Recommendation.t()
  def recommend(%Goal{} = goal, sessions, today \\ Date.utc_today()) do
    weeks_total = recommend_weeks_ceil(goal.date_baseline, goal.date_target)
    weeks_elapsed_raw = recommend_weeks_ceil(goal.date_baseline, today)
    weeks_elapsed = min(max(weeks_elapsed_raw, 0), weeks_total)
    weeks_remaining = max(weeks_total - weeks_elapsed, 0)

    phase = recommend_phase(weeks_elapsed)
    multiplier_base = Map.fetch!(@phase_multipliers, phase)

    matching_sessions =
      sessions
      |> Enum.filter(&(&1.burpee_type == goal.burpee_type))
      |> Enum.sort_by(&session_date/1, {:desc, Date})

    {trend_status, burpee_count_projected_at_goal} =
      recommend_trend(goal, matching_sessions, today)

    multiplier =
      if trend_status == :behind,
        do: multiplier_base + @behind_boost,
        else: multiplier_base

    ratio = recommend_progress_ratio(weeks_elapsed, weeks_total)

    burpee_count_target_linear =
      goal.burpee_count_baseline +
        (goal.burpee_count_target - goal.burpee_count_baseline) * ratio

    duration_sec_target_linear =
      goal.duration_sec_baseline +
        (goal.duration_sec_target - goal.duration_sec_baseline) * ratio

    burpee_count_suggested = round(burpee_count_target_linear * multiplier)
    duration_sec_suggested = round(duration_sec_target_linear)

    sec_per_rep_suggested =
      if burpee_count_suggested > 0 do
        duration_sec_suggested / burpee_count_suggested
      else
        0.0
      end

    rationale =
      recommend_rationale(phase, trend_status, burpee_count_suggested, duration_sec_suggested)

    %Recommendation{
      goal_id: goal.id,
      burpee_type: goal.burpee_type,
      phase: phase,
      trend_status: trend_status,
      burpee_count_suggested: burpee_count_suggested,
      duration_sec_suggested: duration_sec_suggested,
      sec_per_rep_suggested: sec_per_rep_suggested,
      rationale: rationale,
      weeks_remaining: weeks_remaining,
      burpee_count_projected_at_goal: burpee_count_projected_at_goal
    }
  end

  @doc """
  The weekly training-volume target, in seconds. Training aims to hit
  this exactly each week — no more, no less.
  """
  @spec volume_sec_weekly_target() :: integer
  def volume_sec_weekly_target, do: @volume_sec_weekly_target

  @doc """
  Summarise the training volume for the ISO week (Monday–Sunday) that
  contains `date`. Counts `duration_sec_actual` across all sessions
  regardless of `burpee_type`.

  Shape:

      %{
        week_start: Date,
        week_end: Date,
        volume_sec_done: integer,
        volume_sec_target: integer,
        volume_sec_delta: integer   # target - done (positive = under-target)
      }

  Sessions with `duration_sec_actual == nil` contribute 0.
  """
  @spec weekly_volume([WorkoutSession.t()]) :: map
  @spec weekly_volume([WorkoutSession.t()], Date.t()) :: map
  def weekly_volume(sessions, date \\ Date.utc_today()) do
    {week_start, week_end} = weekly_volume_range(date)

    volume_sec_done =
      sessions
      |> Enum.filter(fn session ->
        session_day = session_date(session)

        Date.compare(session_day, week_start) != :lt and
          Date.compare(session_day, week_end) != :gt
      end)
      |> Enum.reduce(0, fn session, acc ->
        acc + (session.duration_sec_actual || 0)
      end)

    %{
      week_start: week_start,
      week_end: week_end,
      volume_sec_done: volume_sec_done,
      volume_sec_target: @volume_sec_weekly_target,
      volume_sec_delta: @volume_sec_weekly_target - volume_sec_done
    }
  end

  defp weekly_volume_range(date) do
    days_since_monday = Date.day_of_week(date) - 1
    week_start = Date.add(date, -days_since_monday)
    week_end = Date.add(week_start, 6)
    {week_start, week_end}
  end

  @doc """
  Project the trend line across the supplied sessions. Returns one
  `{date, burpee_count_projected}` point per unique session date, with
  the y-value computed from a least-squares fit.

  Returns `[]` if fewer than 2 sessions are provided.
  """
  @spec project_trend([WorkoutSession.t()]) :: [{Date.t(), float}]
  def project_trend(sessions) when length(sessions) < @trend_sessions_min, do: []

  def project_trend(sessions) do
    sorted = Enum.sort_by(sessions, &session_date/1, {:asc, Date})
    anchor = session_date(List.first(sorted))

    points =
      Enum.map(sorted, fn session ->
        {Date.diff(session_date(session), anchor), session.burpee_count_actual}
      end)

    {slope, intercept} = least_squares(points)

    sorted
    |> Enum.map(&session_date/1)
    |> Enum.uniq()
    |> Enum.map(fn date ->
      {date, slope * Date.diff(date, anchor) + intercept}
    end)
  end

  # --- recommend helpers ---

  defp recommend_weeks_ceil(from, to) do
    days = Date.diff(to, from)
    if days <= 0, do: 0, else: div(days + 6, 7)
  end

  # weeks_elapsed=0 (day of baseline) starts us in build_1; thereafter
  # the cycle goes build_1, build_2, build_3, deload, build_1, ...
  defp recommend_phase(weeks_elapsed) do
    effective = if weeks_elapsed == 0, do: 1, else: weeks_elapsed

    case rem(effective, 4) do
      1 -> :build_1
      2 -> :build_2
      3 -> :build_3
      0 -> :deload
    end
  end

  defp recommend_progress_ratio(_weeks_elapsed, 0), do: 0.0
  defp recommend_progress_ratio(weeks_elapsed, weeks_total), do: weeks_elapsed / weeks_total

  defp recommend_trend(goal, matching_sessions, today) do
    recent_14 =
      Enum.filter(matching_sessions, fn session ->
        days = Date.diff(today, session_date(session))
        days >= 0 and days <= @consistency_window_days
      end)

    last_window = Enum.take(matching_sessions, @trend_sessions_window)

    cond do
      length(recent_14) < @consistency_sessions_min ->
        {:low_consistency, recommend_project_at_target(last_window, goal)}

      length(last_window) < @trend_sessions_min ->
        {:low_consistency, nil}

      true ->
        projected = recommend_project_at_target(last_window, goal)
        recommend_classify_trend(projected, goal.burpee_count_target)
    end
  end

  defp recommend_classify_trend(nil, _target), do: {:low_consistency, nil}

  defp recommend_classify_trend(projected, target) do
    threshold = target * @trend_threshold

    cond do
      projected >= target + threshold -> {:ahead, projected}
      projected >= target - threshold -> {:on_track, projected}
      true -> {:behind, projected}
    end
  end

  defp recommend_project_at_target(sessions, _goal) when length(sessions) < @trend_sessions_min,
    do: nil

  defp recommend_project_at_target(sessions, goal) do
    sorted = Enum.sort_by(sessions, &session_date/1, {:asc, Date})
    anchor = session_date(List.first(sorted))

    points =
      Enum.map(sorted, fn session ->
        {Date.diff(session_date(session), anchor), session.burpee_count_actual}
      end)

    {slope, intercept} = least_squares(points)
    days_to_target = Date.diff(goal.date_target, anchor)
    slope * days_to_target + intercept
  end

  defp recommend_rationale(phase, trend_status, burpee_count, duration_sec) do
    phase_label =
      case phase do
        :build_1 -> "Build week 1"
        :build_2 -> "Build week 2"
        :build_3 -> "Build week 3"
        :deload -> "Deload week"
      end

    trend_label =
      case trend_status do
        :ahead -> "ahead of pace"
        :on_track -> "on track"
        :behind -> "behind — boosting this week"
        :low_consistency -> "low consistency"
      end

    minutes = Float.round(duration_sec / 60, 1)
    "#{phase_label} · #{trend_label} · target #{burpee_count} reps in #{minutes} min"
  end

  # --- least-squares (pure arithmetic on lists) ---

  defp least_squares(points) do
    n = length(points)
    {sum_x, sum_y, sum_xy, sum_xx} = least_squares_sums(points)
    denom = n * sum_xx - sum_x * sum_x

    if denom == 0 do
      # degenerate case: all x identical — return flat line at mean y
      {0.0, sum_y / n}
    else
      slope = (n * sum_xy - sum_x * sum_y) / denom
      intercept = (sum_y - slope * sum_x) / n
      {slope, intercept}
    end
  end

  defp least_squares_sums(points) do
    Enum.reduce(points, {0, 0, 0, 0}, fn {x, y}, {sx, sy, sxy, sxx} ->
      {sx + x, sy + y, sxy + x * y, sxx + x * x}
    end)
  end

  # --- date extraction (handles DateTime, NaiveDateTime, or Date) ---

  defp session_date(%{inserted_at: %Date{} = date}), do: date
  defp session_date(%{inserted_at: %DateTime{} = dt}), do: DateTime.to_date(dt)
  defp session_date(%{inserted_at: %NaiveDateTime{} = dt}), do: NaiveDateTime.to_date(dt)
end
