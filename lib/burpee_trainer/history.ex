defmodule BurpeeTrainer.History do
  @moduledoc "Read-only local periods, results and actual density for Home and Progress."

  alias BurpeeTrainer.{UserTime, Workouts}
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.Coach.Policy.Week
  alias BurpeeTrainer.Stats.Series
  alias BurpeeTrainer.Workouts.WorkoutSession

  @type period :: String.t()
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
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, since} <- period_start_utc(period, context) do
      {:ok,
       Enum.filter(sessions, fn session ->
         case session.completed_at do
           %DateTime{} = at ->
             DateTime.compare(at, now) != :gt and
               (is_nil(since) or DateTime.compare(at, since) != :lt)

           _ ->
             false
         end
       end)}
    end
  end

  # The period's first local midnight, in UTC: one conversion, not one for each session.
  defp period_start_utc("all", _context), do: {:ok, nil}

  defp period_start_utc(period, context) do
    weeks_back =
      case period do
        "week" -> 0
        "four_weeks" -> 3
        "twelve_weeks" -> 11
        "year" -> 51
      end

    start = Date.add(context.week_start, -7 * weeks_back)

    with {:ok, since, _week_end} <- UserTime.week_bounds_utc(%{context | week_start: start}),
         do: {:ok, since}
  end

  @spec weeks([WorkoutSession.t()], map(), DateTime.t(), period()) ::
          {:ok, [map()]} | {:error, :invalid_timezone}
  def weeks(sessions, user, now, period) when period in ["twelve_weeks", "year", "all"] do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, signed_up_on} <- UserTime.local_date(user.inserted_at, context.timezone) do
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

      seconds_by_day =
        Enum.reduce(dated, %{}, fn {date, session}, acc ->
          Map.update(acc, date, credited_seconds(session), &(&1 + credited_seconds(session)))
        end)

      # The burpee types a day was trained in: those with credited seconds.
      types_by_day =
        for {date, session} <- dated, credited_seconds(session) > 0, reduce: %{} do
          acc ->
            Map.update(
              acc,
              date,
              MapSet.new([session.burpee_type]),
              &MapSet.put(&1, session.burpee_type)
            )
        end

      weeks =
        for offset <- (count - 1)..0//-1 do
          date = Date.add(context.week_start, -7 * offset)

          days =
            for day <- 0..6, date = Date.add(date, day) do
              seconds = Map.get(seconds_by_day, date, 0)
              types = Map.get(types_by_day, date, MapSet.new())

              %{
                date: date,
                seconds: seconds,
                minutes: div(seconds, 60),
                types: Enum.filter([:six_count, :navy_seal], &MapSet.member?(types, &1)),
                future?: Date.compare(date, context.date) == :gt
              }
            end

          seconds = Enum.sum_by(days, & &1.seconds)
          target_sec = Week.new(signed_up_on, date).target_sec

          %{
            start: date,
            seconds: seconds,
            minutes: div(seconds, 60),
            days: days,
            open?: offset == 0,
            target_minutes: div(target_sec, 60),
            target?: seconds >= target_sec
          }
        end

      {:ok, place_in_streak(weeks)}
    end
  end

  @doc "Seconds a session adds to its week: authoritative and not a warmup."
  def credited_seconds(session) do
    if AuthoritativeSession.authoritative?(session) and session.tags != "warmup",
      do: max(session.duration_sec_actual || 0, 0),
      else: 0
  end

  @doc """
  Weeks in a row at their target, back from the latest closed week. The week in progress
  counts once it is met and never breaks the run while it is not.
  """
  def streak(weeks), do: Enum.count(weeks, & &1.streak_week)

  # Each week's place in the current streak (1 for its first week), nil outside it.
  defp place_in_streak(weeks) do
    {open, closed} = Enum.split_with(weeks, & &1.open?)
    run = closed |> Enum.reverse() |> Enum.take_while(& &1.target?) |> length()
    first = length(closed) - run

    closed =
      closed
      |> Enum.with_index()
      |> Enum.map(fn {week, i} ->
        Map.put(week, :streak_week, if(i >= first, do: i - first + 1))
      end)

    closed ++ Enum.map(open, &Map.put(&1, :streak_week, if(&1.target?, do: run + 1)))
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

  @spec results(BurpeeTrainer.Accounts.Scope.t(), DateTime.t()) ::
          {:ok, %{today: [WorkoutSession.t()], week: [WorkoutSession.t()]}} | {:error, term()}
  def results(%BurpeeTrainer.Accounts.Scope{user: user} = scope, now) do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, week_start, _week_end} <- UserTime.week_bounds_utc(context),
         {:ok, week} <-
           filter_sessions(Workouts.list_sessions_since(scope, week_start), user, now, "week") do
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
