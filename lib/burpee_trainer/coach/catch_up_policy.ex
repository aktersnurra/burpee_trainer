defmodule BurpeeTrainer.Coach.CatchUpPolicy do
  @moduledoc "Exact rolling PB and integer catch-up prescription policy."

  alias BurpeeTrainer.Coach.AuthoritativeSession

  @six_weeks_sec 42 * 24 * 60 * 60
  @eligible_remaining_sec 2_400
  @max_duration_min 80

  @spec rolling_pb([BurpeeTrainer.Workouts.WorkoutSession.t() | map()], atom(), DateTime.t()) ::
          {:ok, map()} | :none
  def rolling_pb(sessions, burpee_type, %DateTime{} = now) when is_list(sessions) do
    lower_bound = DateTime.add(now, -@six_weeks_sec, :second)

    sessions
    |> Enum.filter(&eligible_pb_session?(&1, burpee_type, lower_bound, now))
    |> Enum.max_by(&pb_sort_key/1, fn -> nil end)
    |> case do
      nil ->
        :none

      session ->
        {:ok,
         %{
           session_id: Map.get(session, :id),
           reps: Map.get(session, :burpee_count_actual),
           burpee_type: burpee_type,
           duration_sec_planned: 1_200,
           completed_at: Map.get(session, :completed_at)
         }}
    end
  end

  @spec prescription(non_neg_integer(), pos_integer(), map()) :: {:ok, map()} | {:error, atom()}
  def prescription(remaining_sec, capacity_reps, facts)
      when is_integer(remaining_sec) and remaining_sec >= 0 and is_integer(capacity_reps) and
             capacity_reps > 0 and is_map(facts) do
    cond do
      remaining_sec < @eligible_remaining_sec ->
        {:error, :not_eligible}

      true ->
        duration_min = min(@max_duration_min, div(remaining_sec + 59, 60))

        if duration_min in 40..@max_duration_min do
          factor_num = factor_num(duration_min)
          ceiling_reps = div(factor_num * capacity_reps * duration_min, 100 * 20)

          {:ok,
           Map.merge(facts, %{
             remaining_sec: remaining_sec,
             duration_min: duration_min,
             factor_num: factor_num,
             ceiling_reps: ceiling_reps
           })}
        else
          {:error, :duration_out_of_range}
        end
    end
  end

  defp factor_num(duration_min) when duration_min <= 40, do: 75
  defp factor_num(duration_min) when duration_min <= 60, do: 60
  defp factor_num(_duration_min), do: 50

  defp eligible_pb_session?(session, burpee_type, lower_bound, now) do
    AuthoritativeSession.prescribed_plan_pb_eligible?(session) and
      Map.get(session, :burpee_type) == burpee_type and
      Map.get(session, :duration_sec_planned) == 1_200 and
      AuthoritativeSession.within_window?(Map.get(session, :completed_at), lower_bound, now)
  end

  defp pb_sort_key(session) do
    {Map.get(session, :burpee_count_actual) || 0,
     AuthoritativeSession.datetime_sort_key(Map.get(session, :completed_at)),
     Map.get(session, :id) || 0}
  end
end
