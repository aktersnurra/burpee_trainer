defmodule BurpeeTrainer.PerformanceModel do
  @moduledoc "Builds type-specific ability estimates from session history."

  alias BurpeeTrainer.{CurrentCapacity, TrainingState}

  @burpee_types [:six_count, :navy_seal]

  @spec current_capacity([struct()], :six_count | :navy_seal, pos_integer()) ::
          CurrentCapacity.t()
  def current_capacity(history, burpee_type, duration_min) do
    comparable =
      history
      |> non_warmup_sessions()
      |> Enum.filter(&(&1.burpee_type == burpee_type))
      |> Enum.filter(&(session_duration_min(&1) == duration_min))
      |> Enum.sort_by(&session_date_sort_key/1, :desc)
      |> Enum.take(5)

    reps = Enum.map(comparable, & &1.burpee_count_actual) |> Enum.reject(&is_nil/1)

    recent_best_reps = Enum.max(reps, fn -> nil end)
    recent_completed_avg_reps = average(reps)
    last_successful_reps = List.first(reps)

    estimated_reps =
      case {recent_completed_avg_reps, recent_best_reps, last_successful_reps} do
        {nil, nil, nil} -> 0
        {avg, best, last} -> round_capacity(0.50 * avg + 0.30 * best + 0.20 * last)
      end

    %CurrentCapacity{
      burpee_type: burpee_type,
      duration_min: duration_min,
      estimated_reps: estimated_reps,
      recent_best_reps: recent_best_reps,
      recent_completed_avg_reps: recent_completed_avg_reps,
      last_successful_reps: last_successful_reps,
      trend: trend(reps),
      confidence: confidence(length(reps))
    }
  end

  @spec build_training_state([struct()]) :: TrainingState.t()
  def build_training_state(history) do
    history = non_warmup_sessions(history)

    capacities =
      Map.new(@burpee_types, fn burpee_type ->
        {burpee_type, current_capacity(history, burpee_type, 20)}
      end)

    %TrainingState{
      level_by_type: %{
        six_count: level_for(capacities.six_count.estimated_reps, :six_count),
        navy_seal: level_for(capacities.navy_seal.estimated_reps, :navy_seal)
      },
      current_capacity_by_type: capacities,
      fatigue: :normal,
      recent_completion_rate: completion_rate(history),
      recent_missed_sessions: 0,
      confidence:
        average(Enum.map(capacities, fn {_type, capacity} -> capacity.confidence end)) || 0.0
    }
  end

  defp non_warmup_sessions(sessions) do
    Enum.reject(sessions, &(Map.get(&1, :tags) == "warmup"))
  end

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  defp round_capacity(value) when value < 50, do: round(value)
  defp round_capacity(value) when value <= 150, do: round(value / 2) * 2
  defp round_capacity(value), do: round(value / 5) * 5

  defp trend([latest, previous | _]) when latest > previous, do: :improving
  defp trend([latest, previous | _]) when latest < previous, do: :declining
  defp trend([_latest, _previous | _]), do: :flat
  defp trend(_), do: :unknown

  defp confidence(0), do: 0.0
  defp confidence(count), do: min(1.0, count / 5)

  defp completion_rate([]), do: 0.0

  defp completion_rate(history) do
    completed =
      Enum.count(
        history,
        &((&1.burpee_count_actual || 0) > 0 and (&1.duration_sec_actual || 0) > 0)
      )

    completed / length(history)
  end

  defp level_for(reps, :six_count) when reps >= 240, do: :graduated
  defp level_for(reps, :six_count) when reps >= 200, do: :level_4
  defp level_for(reps, :six_count) when reps >= 160, do: :level_3
  defp level_for(reps, :six_count) when reps >= 120, do: :level_2
  defp level_for(reps, :six_count) when reps >= 90, do: :level_1c
  defp level_for(_reps, :six_count), do: :level_1a
  defp level_for(reps, :navy_seal) when reps >= 120, do: :graduated
  defp level_for(reps, :navy_seal) when reps >= 90, do: :level_4
  defp level_for(reps, :navy_seal) when reps >= 70, do: :level_3
  defp level_for(reps, :navy_seal) when reps >= 50, do: :level_2
  defp level_for(reps, :navy_seal) when reps >= 35, do: :level_1c
  defp level_for(_reps, :navy_seal), do: :level_1a

  defp session_duration_min(%{duration_sec_actual: duration_sec}) when is_integer(duration_sec),
    do: div(duration_sec, 60)

  defp session_duration_min(%{duration_sec_actual: duration_sec}) when is_float(duration_sec),
    do: round(duration_sec / 60)

  defp session_duration_min(_session), do: 0

  defp session_date_sort_key(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at)

  defp session_date_sort_key(%{inserted_at: %NaiveDateTime{} = inserted_at}),
    do: inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp session_date_sort_key(_session), do: 0
end
