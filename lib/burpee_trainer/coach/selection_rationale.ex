defmodule BurpeeTrainer.Coach.SelectionRationale do
  @moduledoc """
  The rationale Home shows under a workout a decision model chose. The model returns no
  text, so the sentence is built from facts: the workout's pace against the athlete's last
  session of the same burpee type.
  """

  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  # Within this fraction of the last pace counts as the same pace.
  @same_pace 0.02

  @spec text(WorkoutPlan.t(), [WorkoutSession.t()]) :: String.t()
  def text(%WorkoutPlan{burpee_type: type} = plan, recent_sessions) do
    last = Enum.find(recent_sessions, &(&1.burpee_type == type and paced?(&1)))
    name = type_name(type)

    case last && compare(pace(plan.target_duration_sec, plan.target_reps), session_pace(last)) do
      nil -> "A steady #{name} session to find a pace you can hold."
      :faster -> "A touch quicker than your last #{name} session, a step you can take from here."
      :same -> "The same pace as your last #{name} session, so it starts to feel routine."
      :slower -> "A little easier than your last #{name} session, to keep the habit going."
    end
  end

  defp paced?(%WorkoutSession{burpee_count_actual: reps, duration_sec_actual: sec}),
    do: is_integer(reps) and reps > 0 and is_integer(sec) and sec > 0

  defp session_pace(session), do: pace(session.duration_sec_actual, session.burpee_count_actual)

  defp pace(_duration, reps) when not is_integer(reps) or reps <= 0, do: nil
  defp pace(duration, reps), do: duration / reps

  defp compare(nil, _last), do: nil

  defp compare(planned, last) do
    cond do
      abs(planned - last) <= last * @same_pace -> :same
      planned < last -> :faster
      true -> :slower
    end
  end

  defp type_name(:six_count), do: "six-count"
  defp type_name(:navy_seal), do: "Navy SEAL"
end
