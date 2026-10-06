defmodule BurpeeTrainer.History do
  @moduledoc "Read-only local periods, session pages and actual density for Home."

  alias BurpeeTrainer.{UserTime, Workouts}
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.Stats.Series
  alias BurpeeTrainer.Workouts.WorkoutSession

  @type period :: String.t()
  @type cursor :: {DateTime.t(), pos_integer()} | nil
  @type point :: %{
          id: pos_integer(),
          completed_at: DateTime.t(),
          actual_reps: pos_integer(),
          actual_duration_sec: pos_integer(),
          density: non_neg_integer()
        }

  @spec filter_sessions([WorkoutSession.t()], map(), DateTime.t(), period()) ::
          {:ok, [WorkoutSession.t()]} | {:error, :invalid_timezone}
  def filter_sessions(sessions, user, now, period)
      when period in ["week", "four_weeks", "twelve_weeks", "year", "all"] do
    with {:ok, context} <- UserTime.context(user, now) do
      start =
        case period do
          "week" -> context.week_start
          "four_weeks" -> Date.add(context.week_start, -21)
          "twelve_weeks" -> Date.add(context.week_start, -77)
          "year" -> Date.add(context.week_start, -357)
          "all" -> nil
        end

      {:ok,
       Enum.filter(sessions, fn session ->
         with %DateTime{} = at <- session.completed_at,
              true <- DateTime.compare(at, now) != :gt,
              {:ok, date} <- UserTime.local_date(at, context.timezone) do
           is_nil(start) or Date.compare(date, start) != :lt
         else
           _ -> false
         end
       end)}
    end
  end

  @spec weeks([WorkoutSession.t()], map(), DateTime.t(), period()) ::
          {:ok, [map()]} | {:error, :invalid_timezone}
  def weeks(sessions, user, now, period) when period in ["twelve_weeks", "year", "all"] do
    with {:ok, context} <- UserTime.context(user, now) do
      dated =
        for session <- sessions,
            %DateTime{} = at <- [session.completed_at],
            DateTime.compare(at, now) != :gt,
            {:ok, date} <- [UserTime.local_date(at, context.timezone)],
            do: {date, session}

      count =
        case period do
          "twelve_weeks" ->
            12

          "year" ->
            52

          "all" ->
            earliest = dated |> Enum.map(&elem(&1, 0)) |> Enum.min(fn -> context.week_start end)
            max(12, div(Date.diff(context.week_start, Date.beginning_of_week(earliest)), 7) + 1)
        end

      minutes_by_week =
        Enum.reduce(dated, %{}, fn {date, session}, acc ->
          Map.update(
            acc,
            Date.beginning_of_week(date),
            credited_seconds(session),
            &(&1 + credited_seconds(session))
          )
        end)

      weeks =
        for offset <- (count - 1)..0//-1 do
          date = Date.add(context.week_start, -7 * offset)
          seconds = Map.get(minutes_by_week, date, 0)

          %{
            start: date,
            seconds: seconds,
            minutes: div(seconds, 60),
            open?: offset == 0,
            target?: seconds >= 4_800
          }
        end

      {:ok, weeks}
    end
  end

  @spec week_days([WorkoutSession.t()], map(), DateTime.t(), Date.t()) ::
          {:ok, [map()]} | {:error, :invalid_timezone}
  def week_days(sessions, user, now, week_start) do
    with {:ok, context} <- UserTime.context(user, now) do
      seconds_by_day =
        Enum.reduce(sessions, %{}, fn session, acc ->
          with true <- session.user_id == user.id,
               %DateTime{} = at <- session.completed_at,
               true <- DateTime.compare(at, now) != :gt,
               {:ok, date} <- UserTime.local_date(at, context.timezone),
               true <- Date.beginning_of_week(date) == week_start do
            Map.update(acc, date, credited_seconds(session), &(&1 + credited_seconds(session)))
          else
            _ -> acc
          end
        end)

      {:ok,
       for offset <- 0..6 do
         date = Date.add(week_start, offset)
         seconds = Map.get(seconds_by_day, date, 0)
         %{date: date, seconds: seconds, minutes: div(seconds, 60)}
       end}
    end
  end

  defp credited_seconds(session) do
    if AuthoritativeSession.authoritative?(session) and session.tags != "warmup",
      do: max(session.duration_sec_actual || 0, 0),
      else: 0
  end

  def streak(weeks) do
    weeks
    |> Enum.reject(& &1.open?)
    |> Enum.reverse()
    |> Enum.take_while(& &1.target?)
    |> length()
  end

  @spec points([WorkoutSession.t()]) :: [point()]
  def points(sessions) do
    sessions
    |> Enum.filter(
      &(is_integer(&1.burpee_count_actual) and &1.burpee_count_actual > 0 and
          is_integer(&1.duration_sec_actual) and &1.duration_sec_actual > 0)
    )
    |> Enum.sort_by(&{DateTime.to_unix(&1.completed_at, :microsecond), &1.id})
    |> Enum.map(fn session ->
      %{points: [point]} = Series.progress([session])

      %{
        id: session.id,
        completed_at: session.completed_at,
        actual_reps: session.burpee_count_actual,
        actual_duration_sec: session.duration_sec_actual,
        density: point.normalized_reps
      }
    end)
  end

  @spec summary([WorkoutSession.t()]) :: %{
          sessions: non_neg_integer(),
          total_reps: non_neg_integer(),
          active_time_sec: non_neg_integer(),
          latest_density: non_neg_integer() | nil
        }
  def summary(sessions) do
    measured = points(sessions)

    %{
      sessions: length(sessions),
      total_reps:
        Enum.sum(
          for %{burpee_count_actual: reps} <- sessions, is_integer(reps) and reps > 0, do: reps
        ),
      active_time_sec:
        Enum.sum(
          for %{duration_sec_actual: seconds} <- sessions,
              is_integer(seconds) and seconds > 0,
              do: seconds
        ),
      latest_density: measured |> List.last() |> then(&if(&1, do: &1.density))
    }
  end

  @spec page(BurpeeTrainer.Accounts.Scope.t(), DateTime.t(), period(), cursor()) ::
          {:ok, [WorkoutSession.t()], cursor(), boolean()} | {:error, term()}
  def page(%BurpeeTrainer.Accounts.Scope{user: user} = scope, now, period, cursor \\ nil) do
    with {:ok, _} <- filter_sessions([], user, now, period) do
      scan(scope, now, period, cursor, 5, [])
    end
  end

  defp scan(
         %BurpeeTrainer.Accounts.Scope{user: user} = scope,
         now,
         period,
         cursor,
         remaining,
         accumulated
       ) do
    opts = if cursor, do: [before: cursor], else: []

    case Workouts.list_sessions_page(scope, remaining, opts) do
      {rows, more?} when is_list(rows) ->
        {:ok, matching} = filter_sessions(rows, user, now, period)

        next =
          case List.last(rows) do
            nil -> cursor
            last -> {last.completed_at, last.id}
          end

        accumulated = accumulated ++ matching
        remaining = remaining - length(matching)

        if more? and remaining > 0 do
          scan(scope, now, period, next, remaining, accumulated)
        else
          {:ok, accumulated, next, more?}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec results(BurpeeTrainer.Accounts.Scope.t(), DateTime.t()) ::
          {:ok, %{today: [WorkoutSession.t()], week: [WorkoutSession.t()]}} | {:error, term()}
  def results(%BurpeeTrainer.Accounts.Scope{user: user} = scope, now) do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, week} <- filter_sessions(Workouts.list_sessions(scope), user, now, "week") do
      week = Enum.filter(week, &AuthoritativeSession.authoritative?/1)

      today =
        Enum.filter(
          week,
          &(UserTime.local_date(&1.completed_at, context.timezone) == {:ok, context.date})
        )

      {:ok, %{today: today, week: week}}
    end
  end
end
