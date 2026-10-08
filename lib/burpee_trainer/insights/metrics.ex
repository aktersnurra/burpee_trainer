defmodule BurpeeTrainer.Insights.Metrics do
  @moduledoc "Deterministic metrics from canonical completed snapshots, in the owner's local calendar."
  alias BurpeeTrainer.{Levels, UserTime}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.AuthoritativeSession

  @type id :: String.t()
  @type numeric_unit :: :minutes | :reps | :weeks | :seconds | :percent
  # Levels are existing domain categories, not fabricated numeric ordinals.
  @type metric ::
          %{value: number(), unit: numeric_unit(), label: String.t()}
          | %{value: String.t(), unit: :level, label: String.t()}
  @types [:six_count, :navy_seal]
  @session_ids ~w[session.reps session.duration_min session.pace_sec]

  @doc "Projects only session.* from the exact owned target; missing actual facts never borrow from history."
  @spec for_session(Scope.t(), [map()], [map()], map()) :: {:ok, map()} | {:error, atom()}
  def for_session(%Scope{user: user} = scope, sessions, goals, target) when is_map(target) do
    with true <-
           Map.get(target, :user_id) == user.id and AuthoritativeSession.authoritative?(target),
         %DateTime{} = at <- Map.get(target, :completed_at),
         {:ok, context} <- UserTime.context(user, at) do
      aggregates = for_scope(scope, sessions, goals, at) |> Map.drop(@session_ids)
      projected = compute([target], [], context.date, context.timezone) |> Map.take(@session_ids)
      {:ok, Map.merge(aggregates, projected)}
    else
      _ -> {:error, :invalid_target}
    end
  end

  def for_session(%Scope{}, _sessions, _goals, _target), do: {:error, :invalid_target}

  @spec for_scope(Scope.t(), [map()], [map()], DateTime.t()) :: map()
  def for_scope(%Scope{user: user}, sessions, goals, now) do
    {:ok, context} = UserTime.context(user, now)

    sessions =
      Enum.filter(
        sessions,
        &(&1.user_id == user.id and
            match?(%DateTime{}, &1.completed_at) and DateTime.compare(&1.completed_at, now) != :gt)
      )

    goals = Enum.filter(goals, &(&1.user_id == user.id))
    compute(sessions, goals, context.date, context.timezone)
  end

  @spec compute([map()], [map()], Date.t(), String.t()) :: %{String.t() => metric()}
  def compute(sessions, goals, %Date{} = today, timezone) do
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

    latest =
      Enum.max_by(rows, &{AuthoritativeSession.datetime_sort_key(&1.completed_at), &1.id}, fn ->
        nil
      end)

    base = %{
      "week.minutes" =>
        metric(div(sum(week, :duration_sec_actual), 60), :minutes, "minutes this week"),
      "week.target_minutes" => metric(80, :minutes, "weekly target"),
      "streak.weeks" =>
        metric(streak(credited, start), :weeks, "completed weeks in a row at target")
    }

    per_type =
      for type <- @types, reduce: %{} do
        acc ->
          typed = Enum.filter(credited, &(&1.burpee_type == type))
          current = avg_pace(between(typed, start, today))
          previous = avg_pace(between(typed, Date.add(start, -42), Date.add(start, -1)))

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
                "pace.change_6w.#{type}",
                metric(
                  Float.round(current - previous, 1),
                  :seconds,
                  "change in seconds per rep vs previous six weeks"
                )
              ),
            else: acc
      end

    goal_metrics =
      for g <- goals, g.status == :active, g.burpee_count_target > 0, reduce: %{} do
        acc ->
          best =
            credited
            |> Enum.filter(
              &(&1.burpee_type == g.burpee_type and
                  &1.duration_sec_actual <= g.duration_sec_target)
            )
            |> Enum.map(& &1.burpee_count_actual)
            |> Enum.max(fn -> 0 end)

          Map.put(
            acc,
            "goal.#{g.id}.progress_pct",
            metric(
              min(100, div(best * 100, g.burpee_count_target)),
              :percent,
              "progress toward goal"
            )
          )
      end

    base |> Map.merge(per_type) |> Map.merge(latest_metrics(latest)) |> Map.merge(goal_metrics)
  end

  @spec format(metric()) :: String.t()
  def format(%{value: value}) when is_integer(value), do: Integer.to_string(value)

  def format(%{value: value}) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1)

  def format(%{value: value, unit: :level}) when is_binary(value), do: value

  defp metric(value, unit, label), do: %{value: value, unit: unit, label: label}
  defp sum(rows, field), do: Enum.sum(Enum.map(rows, &Map.fetch!(&1, field)))

  defp between(rows, from, to),
    do:
      Enum.filter(
        rows,
        &(Date.compare(&1.completed_on, from) != :lt and Date.compare(&1.completed_on, to) != :gt)
      )

  defp avg_pace(rows) do
    rows = Enum.filter(rows, &(&1.burpee_count_actual > 0 and &1.duration_sec_actual > 0))

    if rows != [],
      do:
        Enum.sum(Enum.map(rows, &(&1.duration_sec_actual / &1.burpee_count_actual))) /
          length(rows)
  end

  defp latest_metrics(nil), do: %{}

  defp latest_metrics(s) do
    base = %{
      "session.reps" => metric(s.burpee_count_actual, :reps, "reps last session"),
      "session.duration_min" =>
        metric(div(s.duration_sec_actual, 60), :minutes, "minutes last session")
    }

    if s.burpee_count_actual > 0,
      do:
        Map.put(
          base,
          "session.pace_sec",
          metric(
            Float.round(s.duration_sec_actual / s.burpee_count_actual, 1),
            :seconds,
            "seconds per rep last session"
          )
        ),
      else: base
  end

  defp streak(rows, start) do
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
    |> Enum.take_while(&(Map.get(totals, &1, 0) >= 4800))
    |> length()
  end
end
