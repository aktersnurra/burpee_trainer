defmodule BurpeeTrainer.Coach.CatchUpPolicy do
  @moduledoc "The exact rolling personal best a catch-up slot reports."

  alias BurpeeTrainer.Coach.AuthoritativeSession

  @six_weeks_sec 42 * 24 * 60 * 60

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
