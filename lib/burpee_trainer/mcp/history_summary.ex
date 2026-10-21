defmodule BurpeeTrainer.Mcp.HistorySummary do
  @moduledoc """
  Deterministic metrics over trusted, selected authoritative sessions.

  Actual totals include selected warmups and never fall back to planned work.
  Recorded days are distinct local completion dates; training days have positive
  History credit.

  Legacy reps, pace and best density exclude canonical warmups. Measured metrics
  include them. Both paces are rep-weighted seconds per rep, rounded to two decimals,
  and each is null when the sessions it is computed from mix burpee types. Normalized
  throughput is not a prescribed plan personal best. This producer does not establish
  scope, selection, coverage or a valid timezone.
  """

  alias BurpeeTrainer.{History, UserTime}

  @spec summarize([map()], String.t()) :: map()
  def summarize(sessions, timezone) do
    by_type =
      sessions
      |> Enum.group_by(& &1.burpee_type)
      |> Enum.sort_by(fn {type, _} -> type end)
      |> Enum.map(fn {type, typed} ->
        Map.put(totals(typed, timezone), "burpee_type", to_string(type))
      end)

    Map.put(totals(sessions, timezone), "by_type", by_type)
  end

  defp totals(sessions, timezone) do
    types = Map.new(sessions, &{&1.id, &1.burpee_type})
    measured = History.points(sessions)
    legacy = sessions |> Enum.reject(&(&1.tags == "warmup")) |> History.points()
    credited_seconds = Enum.reduce(sessions, 0, &(History.credited_seconds(&1) + &2))

    %{
      "sessions" => length(sessions),
      "actual_reps" => Enum.sum_by(sessions, & &1.burpee_count_actual),
      "elapsed_seconds" => Enum.sum_by(sessions, & &1.duration_sec_actual),
      "credited_seconds" => credited_seconds,
      "minutes" => div(credited_seconds, 60),
      "measurement_samples" => length(measured),
      "unmeasured_sessions" => length(sessions) - length(measured),
      "legacy_measurement_samples" => length(legacy),
      "warmup_sessions" => Enum.count(sessions, &(&1.tags == "warmup")),
      "recorded_days" => day_count(sessions, timezone),
      "training_days" =>
        sessions |> Enum.filter(&(History.credited_seconds(&1) > 0)) |> day_count(timezone),
      "reps" => point_total(legacy, :actual_reps),
      "best_reps_per_20_min" => best_density(legacy),
      "best_normalized_reps_per_20_min" => best_density(measured),
      "average_pace_sec" => pace(legacy, types),
      "measured_average_pace_sec" => pace(measured, types),
      "pace_comparability" =>
        if(mixed?(measured, types), do: "mixed_burpee_types", else: "single_burpee_type")
    }
  end

  defp day_count(sessions, timezone) do
    sessions
    |> Enum.map(fn session ->
      {:ok, date} = UserTime.local_date(session.completed_at, timezone)
      date
    end)
    |> Enum.uniq()
    |> length()
  end

  defp point_total(points, field), do: Enum.reduce(points, 0, &(Map.fetch!(&1, field) + &2))

  defp best_density(points), do: points |> Enum.map(& &1.density) |> Enum.max(fn -> nil end)

  defp mixed?(points, types),
    do: points |> Enum.map(&types[&1.id]) |> Enum.uniq() |> length() > 1

  defp pace([], _types), do: nil

  defp pace(points, types) do
    if mixed?(points, types) do
      nil
    else
      reps = point_total(points, :actual_reps)
      seconds = point_total(points, :actual_duration_sec)
      Float.round(seconds / reps, 2)
    end
  end
end
