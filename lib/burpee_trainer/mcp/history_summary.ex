defmodule BurpeeTrainer.Mcp.HistorySummary do
  @moduledoc """
  Deterministic metrics over trusted, selected authoritative sessions.

  Actual totals include selected warmups and count only nonnegative integers;
  missing/invalid values never fall back to planned work. Recorded days are distinct
  local completion dates; training days have positive History credit.

  Legacy reps, pace and best density exclude canonical warmups. Measured metrics
  include them. Both paces are rep-weighted seconds per rep, rounded to two decimals,
  and are null for mixed-type selections. Normalized throughput is not a prescribed
  plan personal best. This producer does not establish scope, selection or coverage.
  """

  alias BurpeeTrainer.{History, UserTime}

  @spec summarize([map()], String.t()) :: {:ok, map()} | {:error, :invalid_timezone}
  def summarize(sessions, timezone) do
    # Validate even an empty selection without consulting a request clock.
    with {:ok, _} <- UserTime.local_date(~U[2000-01-01 00:00:00Z], timezone) do
      by_type =
        sessions
        |> Enum.group_by(& &1.burpee_type)
        |> Enum.sort_by(fn {type, _} -> type end)
        |> Enum.map(fn {type, typed} ->
          Map.put(totals(typed, timezone), "burpee_type", to_string(type))
        end)

      {:ok, Map.put(totals(sessions, timezone), "by_type", by_type)}
    end
  end

  defp totals(sessions, timezone) do
    measured = History.points(sessions)
    legacy = sessions |> Enum.reject(&(&1.tags == "warmup")) |> History.points()
    reps = actual_values(sessions, :burpee_count_actual)
    seconds = actual_values(sessions, :duration_sec_actual)
    credited_seconds = Enum.reduce(sessions, 0, &(credit(&1) + &2))
    mixed? = sessions |> Enum.map(& &1.burpee_type) |> Enum.uniq() |> length() > 1

    %{
      "sessions" => length(sessions),
      "actual_reps" => Enum.sum(reps),
      "elapsed_seconds" => Enum.sum(seconds),
      "credited_seconds" => credited_seconds,
      "minutes" => div(credited_seconds, 60),
      "actual_reps_samples" => length(reps),
      "elapsed_seconds_samples" => length(seconds),
      "missing_actual_reps" => length(sessions) - length(reps),
      "missing_elapsed_seconds" => length(sessions) - length(seconds),
      "measurement_samples" => length(measured),
      "unmeasured_sessions" => length(sessions) - length(measured),
      "legacy_measurement_samples" => length(legacy),
      "warmup_sessions" => Enum.count(sessions, &(&1.tags == "warmup")),
      "recorded_days" => day_count(sessions, timezone),
      "training_days" => sessions |> Enum.filter(&(credit(&1) > 0)) |> day_count(timezone),
      "reps" => point_total(legacy, :actual_reps),
      "best_reps_per_20_min" => best_density(legacy),
      "best_normalized_reps_per_20_min" => best_density(measured),
      "average_pace_sec" => pace(legacy, mixed?),
      "measured_average_pace_sec" => pace(measured, mixed?),
      "pace_comparability" => if(mixed?, do: "mixed_burpee_types", else: "single_burpee_type")
    }
  end

  defp actual_values(sessions, field) do
    for session <- sessions, value = Map.fetch!(session, field), valid_actual?(value), do: value
  end

  defp valid_actual?(value), do: is_integer(value) and value >= 0

  # History credit assumes persisted numeric durations; invalid pure input is missing.
  defp credit(session) do
    if valid_actual?(session.duration_sec_actual), do: History.credited_seconds(session), else: 0
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

  defp pace(_, true), do: nil
  defp pace([], false), do: nil

  defp pace(points, false) do
    reps = point_total(points, :actual_reps)
    seconds = point_total(points, :actual_duration_sec)
    Float.round(seconds / reps, 2)
  end
end
