defmodule BurpeeTrainer.CoachTargetPlanner do
  @moduledoc "Suggests type-specific 20 minute rep targets for performance goals."

  alias BurpeeTrainer.CoachTargetPlanner.{Input, NoActiveGoal, Suggestion}
  alias BurpeeTrainer.PerformanceModel

  @max_jump_ratio %{low: 0.03, normal: 0.06, high: 0.10}

  @spec suggest_targets(Input.t()) :: {:ok, [Suggestion.t()]} | {:error, NoActiveGoal.t()}
  def suggest_targets(%Input{goal: nil, burpee_type: burpee_type}) do
    {:error, NoActiveGoal.exception(burpee_type: burpee_type)}
  end

  def suggest_targets(%Input{} = input) do
    current =
      (input.history || [])
      |> PerformanceModel.current_capacity(input.burpee_type, 20)
      |> maybe_apply_goal_baseline(input.goal)

    sessions_remaining = sessions_remaining(input.goal, input.today)

    raw_on_track_target =
      required_next_target(
        current_reps: current.estimated_reps,
        goal_reps: input.goal.target_reps,
        sessions_remaining: sessions_remaining
      )

    recommended_target =
      clamp_recommended_target(raw_on_track_target, current.estimated_reps, input.training_state)

    {:ok,
     [
       suggestion(
         input,
         current,
         :on_track,
         "Stay on track",
         raw_on_track_target,
         risk_for(raw_on_track_target, current.estimated_reps)
       ),
       suggestion(
         input,
         current,
         :recommended,
         "Recommended today",
         recommended_target,
         risk_for(recommended_target, current.estimated_reps)
       ),
       suggestion(
         input,
         current,
         :safe_progress,
         "Small step",
         safe_progress_target(current.estimated_reps, recommended_target),
         :low
       ),
       suggestion(
         input,
         current,
         :stretch,
         "Push day",
         stretch_target(current.estimated_reps),
         :high
       )
     ]
     |> Enum.uniq_by(&{&1.kind, &1.burpee_count_target})}
  end

  defp maybe_apply_goal_baseline(%{estimated_reps: 0, confidence: confidence} = current, %{
         start_reps: reps
       })
       when is_integer(reps) and reps > 0 and confidence == 0.0 do
    %{current | estimated_reps: reps, recent_best_reps: reps, last_successful_reps: reps}
  end

  defp maybe_apply_goal_baseline(current, _goal), do: current

  defp required_next_target(
         current_reps: current_reps,
         goal_reps: goal_reps,
         sessions_remaining: sessions_remaining
       ) do
    gain = (goal_reps - current_reps) / max(sessions_remaining, 1)
    max(current_reps, current_reps + gain) |> round_human_target()
  end

  defp sessions_remaining(%{target_date: nil}, _today), do: 8
  defp sessions_remaining(_goal, nil), do: 8

  defp sessions_remaining(%{target_date: target_date}, today) do
    days = max(Date.diff(target_date, today), 0)
    max(1, ceil(days / 7 * 2))
  end

  defp clamp_recommended_target(target, current_reps, training_state) do
    fatigue =
      Map.get(@max_jump_ratio, training_state && training_state.fatigue, @max_jump_ratio.normal)

    max_recommended = current_reps * (1 + fatigue)
    min(target, max_recommended) |> round_human_target()
  end

  defp safe_progress_target(0, _recommended_target), do: 1

  defp safe_progress_target(current_reps, recommended_target) do
    min(round_human_target(current_reps * 1.03), recommended_target)
  end

  defp stretch_target(0), do: 1
  defp stretch_target(current_reps), do: round_human_target(current_reps * 1.10)

  defp risk_for(_target, current_reps) when current_reps <= 0, do: :high

  defp risk_for(target, current_reps) do
    jump_ratio = (target - current_reps) / current_reps

    cond do
      jump_ratio <= @max_jump_ratio.low -> :low
      jump_ratio <= @max_jump_ratio.normal -> :normal
      true -> :high
    end
  end

  defp suggestion(input, current, kind, title, target, risk) do
    %Suggestion{
      kind: kind,
      title: title,
      burpee_type: input.burpee_type,
      target_duration_min: 20,
      burpee_count_target: target,
      current_estimate_reps: current.estimated_reps,
      goal_reps: input.goal.target_reps,
      status: goal_status(current.estimated_reps, input.goal.target_reps),
      risk: risk,
      confidence: current.confidence,
      rationale: rationale(input, current, target),
      plan_input_defaults: %{pacing_style: :even, additional_rests: []}
    }
  end

  defp goal_status(current, goal) when current >= goal, do: :ahead
  defp goal_status(current, goal) when current >= goal * 0.9, do: :on_track
  defp goal_status(_current, _goal), do: :behind

  defp rationale(input, current, target) do
    [
      "Your current estimate is #{current.estimated_reps} #{format_type(input.burpee_type)} burpees in 20 min.",
      "#{target} keeps this session aligned with your performance goal."
    ]
  end

  defp round_human_target(value) when value < 50, do: round(value)
  defp round_human_target(value) when value <= 150, do: round(value / 2) * 2
  defp round_human_target(value), do: round(value / 5) * 5

  defp format_type(type), do: type |> Atom.to_string() |> String.replace("_", "-")
end
