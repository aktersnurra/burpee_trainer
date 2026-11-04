defmodule BurpeeTrainer.Insights.Metrics do
  @moduledoc "Deterministic metrics from canonical completed snapshots, in the owner's local calendar."
  alias BurpeeTrainer.{Levels, UserTime}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.Coach.Policy.Week
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Workouts.SetBreakdown

  @type id :: String.t()
  @type numeric_unit :: :minutes | :reps | :weeks | :seconds | :percent | :days | :sets
  # Levels and statuses are named categories, not fabricated numeric ordinals.
  @type metric ::
          %{value: number(), unit: numeric_unit(), label: String.t()}
          | %{value: String.t(), unit: :level | :status, label: String.t()}
  @types [:six_count, :navy_seal]
  # Facts about one session: the latest, or the one being narrated.
  @session_prefixes ["session.", "same_workout."]

  @doc "Projects only session.* from the exact owned target; missing actual facts never borrow from history."
  @spec for_session(Scope.t(), [map()], [map()], map()) :: {:ok, map()} | {:error, atom()}
  def for_session(%Scope{user: user} = scope, sessions, goals, target) when is_map(target) do
    with true <-
           Map.get(target, :user_id) == user.id and AuthoritativeSession.authoritative?(target),
         %DateTime{} = at <- Map.get(target, :completed_at),
         {:ok, context} <- UserTime.context(user, at),
         {:ok, signed_up_on} <- UserTime.local_date(user.inserted_at, context.timezone) do
      aggregates = for_scope(scope, sessions, goals, at) |> Map.reject(&session_fact?/1)
      key = sort_key(target)
      earlier = Enum.filter(sessions, &(&1.user_id == user.id and sort_key(&1) < key))

      project = &compute(&1, [], context.date, context.timezone, signed_up_on)
      projected = project.([target]) |> Map.filter(&session_fact?/1)

      # Against earlier sessions only while the target itself is the latest fact, so a
      # target missing its actuals never borrows another session's comparison.
      projected =
        if Map.has_key?(projected, "session.reps"),
          do: Map.merge(project.([target | earlier]) |> Map.filter(&same_workout?/1), projected),
          else: projected

      {:ok, Map.merge(aggregates, projected)}
    else
      _ -> {:error, :invalid_target}
    end
  end

  def for_session(%Scope{}, _sessions, _goals, _target), do: {:error, :invalid_target}

  defp session_fact?({id, _metric}), do: String.starts_with?(id, @session_prefixes)
  defp same_workout?({id, _metric}), do: String.starts_with?(id, "same_workout.")

  defp sort_key(session),
    do: {AuthoritativeSession.datetime_sort_key(session.completed_at), session.id}

  @spec for_scope(Scope.t(), [map()], [map()], DateTime.t()) :: map()
  def for_scope(%Scope{user: user}, sessions, goals, now) do
    {:ok, context} = UserTime.context(user, now)
    {:ok, signed_up_on} = UserTime.local_date(user.inserted_at, context.timezone)

    sessions =
      Enum.filter(
        sessions,
        &(&1.user_id == user.id and
            match?(%DateTime{}, &1.completed_at) and DateTime.compare(&1.completed_at, now) != :gt)
      )

    goals = Enum.filter(goals, &(&1.user_id == user.id))
    compute(sessions, goals, context.date, context.timezone, signed_up_on)
  end

  @doc "Weekly targets follow `Coach.Policy.Week` for a user who signed up on `signed_up_on`."
  @spec compute([map()], [map()], Date.t(), String.t(), Date.t()) :: %{String.t() => metric()}
  def compute(sessions, goals, %Date{} = today, timezone, %Date{} = signed_up_on) do
    {:ok, _} = UserTime.resolve_local(today, ~T[00:00:00], timezone)

    rows =
      for s <- sessions,
          AuthoritativeSession.authoritative?(s),
          is_integer(s.burpee_count_actual) and s.burpee_count_actual >= 0,
          is_integer(s.duration_sec_actual) and s.duration_sec_actual >= 0,
          s.burpee_type in @types,
          {:ok, date} <- [UserTime.local_date(s.completed_at, timezone)],
          Date.compare(date, today) != :gt,
          do: Map.put(s, :completed_on, date)

    start = Date.beginning_of_week(today)
    credited = Enum.reject(rows, &(Map.get(&1, :tags) == "warmup"))
    week = between(credited, start, today)

    latest = Enum.max_by(rows, &sort_key/1, fn -> nil end)

    base = %{
      "week.minutes" =>
        metric(div(sum(week, :duration_sec_actual), 60), :minutes, "minutes this week"),
      "week.target_minutes" =>
        metric(div(Week.new(signed_up_on, start).target_sec, 60), :minutes, "weekly target"),
      "streak.weeks" =>
        metric(
          streak(credited, start, signed_up_on),
          :weeks,
          "completed weeks in a row at target"
        )
    }

    per_type =
      for type <- @types, reduce: %{} do
        acc ->
          typed = Enum.filter(credited, &(&1.burpee_type == type))
          current = active_pace(between(typed, start, today))
          previous = active_pace(between(typed, Date.add(start, -42), Date.add(start, -1)))

          acc =
            acc
            |> Map.put(
              "week.reps.#{type}",
              metric(
                sum(Enum.filter(week, &(&1.burpee_type == type)), :burpee_count_actual),
                :reps,
                "#{type} reps this week"
              )
            )
            |> Map.put(
              "level.#{type}",
              metric(
                Atom.to_string(Levels.level_for_type(credited, type)),
                :level,
                "current #{type} level"
              )
            )

          if current && previous,
            do:
              Map.put(
                acc,
                "active_pace.change_6w.#{type}",
                metric(
                  Float.round(current - previous, 1),
                  :seconds,
                  "change in seconds per rep inside sets, rests excluded, camera sessions " <>
                    "this week vs the previous six weeks; negative is faster"
                )
              ),
            else: acc
      end

    goal_metrics =
      for g <- goals, g.status == :active, g.burpee_count_target > 0, reduce: %{} do
        acc ->
          best = goal_best(credited, g.burpee_type)

          Map.merge(acc, %{
            "goal.#{g.id}.progress_pct" =>
              metric(
                min(100, div(best * 100, g.burpee_count_target)),
                :percent,
                "progress toward goal"
              ),
            "goal.#{g.id}.best_reps" => metric(best, :reps, "best reps in a 20-minute session"),
            "goal.#{g.id}.target_reps" => metric(g.burpee_count_target, :reps, "goal reps"),
            "goal.#{g.id}.days_left" =>
              metric(max(0, Date.diff(g.date_target, today)), :days, "days until goal date")
          })
      end

    previous_start = Date.add(start, -7)

    last_week =
      last_week_metrics(
        Date.compare(previous_start, Date.beginning_of_week(signed_up_on)) != :lt,
        between(credited, previous_start, Date.add(start, -1)),
        Week.new(signed_up_on, previous_start)
      )

    base
    |> Map.merge(per_type)
    |> Map.merge(latest_metrics(latest))
    |> Map.merge(same_workout_metrics(latest, rows))
    |> Map.merge(goal_metrics)
    |> Map.merge(last_week)
  end

  @doc "Best reps toward a goal of `burpee_type`: the most in one 20-minute session, warmups excluded."
  @spec goal_best([map()], atom()) :: non_neg_integer()
  def goal_best(sessions, burpee_type) do
    sessions
    |> Enum.reject(&(Map.get(&1, :tags) == "warmup"))
    |> Enum.filter(
      &(&1.burpee_type == burpee_type and is_integer(&1.burpee_count_actual) and
          &1.duration_sec_actual in Goal.session_duration_sec())
    )
    |> Enum.map(& &1.burpee_count_actual)
    |> Enum.max(fn -> 0 end)
  end

  @spec format(metric()) :: String.t()
  def format(%{value: value}) when is_integer(value), do: Integer.to_string(value)

  def format(%{value: value}) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1)

  def format(%{value: value}) when is_binary(value), do: value

  defp metric(value, unit, label), do: %{value: value, unit: unit, label: label}
  defp sum(rows, field), do: Enum.sum(Enum.map(rows, &Map.fetch!(&1, field)))

  defp between(rows, from, to),
    do:
      Enum.filter(
        rows,
        &(Date.compare(&1.completed_on, from) != :lt and Date.compare(&1.completed_on, to) != :gt)
      )

  # Seconds per rep inside sets over the camera sessions with complete sets: their time from
  # each set's beep to its last rep, over their reps. Elapsed pace is no trend: it moves
  # with how long the chosen workouts rest, and a timed session's is the plan's.
  defp active_pace(rows) do
    totals =
      for row <- rows,
          sets = camera_breakdown(row).sets,
          set <- sets,
          set["finish_sec"],
          reduce: {0.0, 0} do
        {seconds, reps} -> {seconds + set["finish_sec"], reps + set["reps"]}
      end

    case totals do
      {_seconds, 0} -> nil
      {seconds, reps} -> seconds / reps
    end
  end

  # Only a session whose camera caught the opening is broken down: otherwise its sets
  # could be a camera that was not working, not the athlete.
  defp camera_breakdown(session) do
    if Map.get(session, :capture_mode) == :tracked and is_boolean(Map.get(session, :kept_up)),
      do:
        SetBreakdown.for_session(
          Map.get(session, :cadence_ms),
          Map.get(session, :program_snapshot)
        ),
      else: SetBreakdown.for_session(nil, nil)
  end

  # A week before the sign-up week was never a training week, so it has no last-week facts.
  defp last_week_metrics(true = _trained?, rows, %Week{target_sec: target_sec}) do
    %{
      "last_week.minutes" =>
        metric(div(sum(rows, :duration_sec_actual), 60), :minutes, "minutes last week"),
      "last_week.target_minutes" => metric(div(target_sec, 60), :minutes, "last week's target")
    }
  end

  defp last_week_metrics(false = _trained?, _rows, _week), do: %{}

  defp latest_metrics(nil), do: %{}

  defp latest_metrics(s) do
    base = %{
      "session.reps" => metric(s.burpee_count_actual, :reps, "reps last session"),
      "session.duration_min" =>
        metric(div(s.duration_sec_actual, 60), :minutes, "minutes last session")
    }

    base =
      if s.burpee_count_actual > 0,
        do:
          Map.put(
            base,
            "session.elapsed_pace_sec",
            metric(
              Float.round(s.duration_sec_actual / s.burpee_count_actual, 1),
              :seconds,
              "seconds per rep last session, rests included"
            )
          ),
        else: base

    Map.merge(base, camera_metrics(s))
  end

  defp camera_metrics(s) do
    case {Map.get(s, :fatigue_coverage), Map.get(s, :kept_up)} do
      {nil, _} ->
        %{}

      # The camera missed the opening: how the session went inside it is not known.
      {coverage, nil} ->
        %{"session.camera_coverage_pct" => coverage_metric(coverage)}

      {coverage, kept_up} ->
        breakdown = camera_breakdown(s)

        %{
          "session.camera_coverage_pct" => coverage_metric(coverage),
          "session.kept_up" =>
            metric(
              if(kept_up, do: "kept up", else: "fell behind"),
              :status,
              "whether they stayed on or ahead of the beat to the end"
            )
        }
        |> put_some(
          "session.slip_at_min",
          Map.get(s, :slip_at_sec),
          &metric(Float.round(&1 / 60, 1), :minutes, "minute they fell behind the beat for good")
        )
        |> put_some(
          "session.active_pace_sec",
          breakdown.active_pace_sec,
          &metric(Float.round(&1, 1), :seconds, "seconds per rep inside sets, rests excluded")
        )
        |> Map.merge(slack_metrics(breakdown.window_slack))
        |> Map.merge(fade_metrics(breakdown.fade))
    end
  end

  defp coverage_metric(coverage),
    do: metric(round(coverage * 100), :percent, "share of planned reps the camera caught")

  defp slack_metrics(nil), do: %{}

  defp slack_metrics(slack) do
    %{
      "session.slack_first_sec" =>
        metric(
          Float.round(slack["first_sec"], 1),
          :seconds,
          "seconds left of the first set's window"
        ),
      "session.slack_last_sec" =>
        metric(
          Float.round(slack["last_sec"], 1),
          :seconds,
          "seconds left of the last measured set's window"
        ),
      "session.slack_trend_sec" =>
        metric(
          Float.round(slack["trend_sec_per_set"], 1),
          :seconds,
          "change in window left per set; negative is the window shrinking"
        ),
      "session.slack_sets" =>
        metric(slack["sets_measured"], :sets, "sets behind the slack figures")
    }
  end

  @patterns %{
    "none" => "held their pace",
    "within_sets" => "slowed inside each set",
    "across_sets" => "slowed from set to set",
    "both" => "slowed inside sets and from set to set"
  }

  defp fade_metrics(nil), do: %{}

  defp fade_metrics(fade) do
    %{
      "session.fade" =>
        metric(Map.fetch!(@patterns, fade["pattern"]), :status, "where the pace faded")
    }
    |> put_some(
      "session.within_set_slowdown_pct",
      fade["within_set"],
      &metric(round(&1 * 100), :percent, "how much slower the end of a set was than its start")
    )
    |> put_some(
      "session.across_sets_slowdown_pct",
      fade["across_sets"],
      &metric(round(&1 * 100), :percent, "how much slower the last sets were than the first")
    )
  end

  # The latest session against the previous camera session of the same program.
  defp same_workout_metrics(nil, _rows), do: %{}

  defp same_workout_metrics(latest, rows) do
    hash = Map.get(latest, :content_hash)
    key = sort_key(latest)

    previous =
      rows
      |> Enum.filter(
        &(is_binary(hash) and Map.get(&1, :content_hash) == hash and sort_key(&1) < key and
            camera_breakdown(&1).sets != [])
      )
      |> Enum.max_by(&sort_key/1, fn -> nil end)

    with %{} <- previous,
         %{} = change <-
           SetBreakdown.compare(camera_breakdown(latest).sets, camera_breakdown(previous).sets) do
      %{
        "same_workout.finish_change_sec" =>
          metric(
            Float.round(change["finish_change_sec"] / 1, 1),
            :seconds,
            "median change in each set's finish vs the last time; negative is faster"
          ),
        "same_workout.sets_faster" =>
          metric(change["sets_faster"], :sets, "sets finished faster than the last time"),
        "same_workout.sets_compared" =>
          metric(change["sets_compared"], :sets, "sets compared with the last time"),
        "same_workout.days_since" =>
          metric(
            Date.diff(latest.completed_on, previous.completed_on),
            :days,
            "days since the last time"
          )
      }
    else
      _ -> %{}
    end
  end

  defp put_some(map, _id, nil, _build), do: map
  defp put_some(map, id, value, build), do: Map.put(map, id, build.(value))

  defp streak(rows, start, signed_up_on) do
    totals =
      Enum.reduce(rows, %{}, fn s, acc ->
        Map.update(
          acc,
          Date.beginning_of_week(s.completed_on),
          s.duration_sec_actual,
          &(&1 + s.duration_sec_actual)
        )
      end)

    Stream.iterate(Date.add(start, -7), &Date.add(&1, -7))
    |> Enum.take_while(&(Map.get(totals, &1, 0) >= Week.new(signed_up_on, &1).target_sec))
    |> length()
  end
end
