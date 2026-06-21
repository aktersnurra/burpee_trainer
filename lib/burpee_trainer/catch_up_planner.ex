defmodule BurpeeTrainer.CatchUpPlanner do
  @moduledoc """
  Type-locked catch-up planner for explicit remaining-week planning.

  The selected burpee type is a hard input. This planner never chooses between
  burpee types and never creates mixed-type plans.
  """

  alias BurpeeTrainer.CatchUpPlanner.{Input, Metadata, Plan, SelectedSession}
  alias BurpeeTrainer.CoachTargetPlanner
  alias BurpeeTrainer.CoachTargetPlanner.Input, as: CoachInput
  alias BurpeeTrainer.PlanSolver.Input, as: PlanInput

  @valid_types [:six_count, :navy_seal]

  @spec plan(Input.t()) :: {:ok, Plan.t()} | {:error, map()}
  def plan(%Input{selected_burpee_type: nil}) do
    {:error,
     %{
       reason: :selected_burpee_type_required,
       message: "Choose Six-count or Navy SEAL before planning catch-up work."
     }}
  end

  def plan(%Input{selected_burpee_type: selected_burpee_type} = input)
      when selected_burpee_type in @valid_types do
    session_durations = session_durations(input.duration_min)
    candidates = candidate_sessions(input, session_durations)
    selected = select_sessions(candidates)
    split_effect = weekly_split_effect(input, selected)

    {:ok,
     %Plan{
       selected_burpee_type: selected_burpee_type,
       total_duration_min: Enum.sum(Enum.map(selected, & &1.duration_min)),
       selected_sessions: selected,
       expected_progress_value: expected_progress_value(selected, input),
       fatigue_cost: fatigue_cost(selected),
       risk: plan_risk(selected),
       canonical?: split_effect == :preserves_contract,
       weekly_split_effect: split_effect,
       rationale: rationale(split_effect, selected),
       metadata: %Metadata{
         selected_candidate_count: length(selected),
         rejected_candidate_count: max(length(candidates) - length(selected), 0),
         objective_value: expected_progress_value(selected, input) - fatigue_cost(selected),
         objective_breakdown: %{
           progress: expected_progress_value(selected, input),
           fatigue: fatigue_cost(selected)
         }
       }
     }}
  end

  def plan(%Input{}), do: {:error, %{reason: :invalid_selected_burpee_type}}

  defp session_durations(duration_min), do: [duration_min]

  defp candidate_sessions(input, session_durations) do
    suggestions = coach_suggestions(input)

    Enum.flat_map(Enum.with_index(session_durations, 1), fn {duration_min, slot_index} ->
      suggestions
      |> Enum.filter(&(&1.kind in [:maintenance, :safe_progress, :recommended, :stretch]))
      |> Enum.map(fn suggestion ->
        selected_session(input, suggestion, duration_min, slot_index)
      end)
    end)
  end

  defp coach_suggestions(input) do
    coach_input = %CoachInput{
      goal: input.performance_goal,
      history: input.history || [],
      training_state: input.training_state,
      weekly_status: input.weekly_status,
      burpee_type: input.selected_burpee_type,
      target_duration_min: 20,
      today: input.today
    }

    case CoachTargetPlanner.suggest_targets(coach_input) do
      {:ok, suggestions} -> suggestions
      {:error, _reason} -> fallback_suggestions(input)
    end
  end

  defp fallback_suggestions(input) do
    capacity = input.training_state.current_capacity_by_type[input.selected_burpee_type]
    estimate = max((capacity && capacity.estimated_reps) || 1, 1)

    [
      %{kind: :maintenance, burpee_count_target: estimate, risk: :low},
      %{kind: :safe_progress, burpee_count_target: round(estimate * 1.03), risk: :low},
      %{kind: :recommended, burpee_count_target: round(estimate * 1.06), risk: :normal},
      %{kind: :stretch, burpee_count_target: round(estimate * 1.10), risk: :high}
    ]
  end

  defp selected_session(input, suggestion, duration_min, slot_index) do
    level = Map.fetch!(input.training_state.level_by_type, input.selected_burpee_type)
    target_reps = catch_up_target(input, suggestion, duration_min)
    suggestion_kind = catch_up_suggestion_kind(input, suggestion, target_reps, duration_min)

    %SelectedSession{
      burpee_type: input.selected_burpee_type,
      duration_min: duration_min,
      target_reps: target_reps,
      suggestion_kind: suggestion_kind,
      plan_input: %PlanInput{
        name: "Catch-up #{slot_index}",
        burpee_type: input.selected_burpee_type,
        target_duration_min: duration_min,
        burpee_count_target: target_reps,
        pacing_style: :even,
        additional_rests: [],
        level: level
      }
    }
  end

  defp catch_up_target(input, suggestion, duration_min) do
    base_target = scale_target(suggestion.burpee_count_target, duration_min)

    case catch_up_intensity_cap(input, duration_min) do
      nil -> base_target
      cap -> min(base_target, cap)
    end
  end

  defp catch_up_intensity_cap(%Input{duration_min: total_duration_min} = input, duration_min)
       when total_duration_min > 20 do
    capacity = input.training_state.current_capacity_by_type[input.selected_burpee_type]
    estimate = (capacity && capacity.estimated_reps) || 0

    if estimate > 0 do
      estimate
      |> Kernel.*(duration_intensity_factor(total_duration_min))
      |> scale_target(duration_min)
      |> round()
    end
  end

  defp catch_up_intensity_cap(_input, _duration_min), do: nil

  defp duration_intensity_factor(duration_min) when duration_min <= 20, do: 1.0
  defp duration_intensity_factor(duration_min) when duration_min <= 30, do: 0.85
  defp duration_intensity_factor(duration_min) when duration_min <= 40, do: 0.75
  defp duration_intensity_factor(duration_min) when duration_min <= 60, do: 0.60
  defp duration_intensity_factor(_duration_min), do: 0.50

  defp catch_up_suggestion_kind(input, suggestion, target_reps, duration_min) do
    if catch_up_intensity_cap(input, duration_min) &&
         target_reps < scale_target(suggestion.burpee_count_target, duration_min) do
      :maintenance
    else
      suggestion.kind
    end
  end

  defp scale_target(target, 20), do: target
  defp scale_target(target, duration_min), do: round(target * duration_min / 20)

  defp select_sessions(candidates) do
    candidates
    |> Enum.group_by(& &1.duration_min)
    |> Enum.flat_map(fn {_duration_min, family} ->
      family
      |> Enum.group_by(& &1.plan_input.name)
      |> Enum.map(fn {_slot, slot_candidates} -> choose_candidate(slot_candidates) end)
    end)
  end

  defp choose_candidate(candidates) do
    Enum.min_by(candidates, fn candidate ->
      {risk_penalty(candidate.suggestion_kind), -candidate.target_reps}
    end)
  end

  defp risk_penalty(:recommended), do: 0
  defp risk_penalty(:safe_progress), do: 1
  defp risk_penalty(:maintenance), do: 2
  defp risk_penalty(:stretch), do: 3
  defp risk_penalty(_kind), do: 4

  defp weekly_split_effect(input, selected) do
    selected_min = Enum.sum(Enum.map(selected, & &1.duration_min))
    completed_after = input.weekly_status.completed_min + selected_min
    selected_standard_count = Enum.count(selected, &(&1.duration_min == 20))
    all_standard_sessions? = Enum.all?(selected, &(&1.duration_min == 20))

    remaining_for_type =
      remaining_standard_sessions(input.remaining_slots, input.selected_burpee_type)

    cond do
      completed_after > input.weekly_status.target_min ->
        :over_target

      all_standard_sessions? and selected_standard_count <= remaining_for_type and
          selected_min == input.duration_min ->
        :preserves_contract

      true ->
        :counts_but_non_standard
    end
  end

  defp remaining_standard_sessions(slots, burpee_type) do
    Enum.count(slots || [], &(&1.burpee_type == burpee_type and &1.duration_min == 20))
  end

  defp expected_progress_value([], _input), do: 0.0

  defp expected_progress_value(selected, input) do
    capacity = input.training_state.current_capacity_by_type[input.selected_burpee_type]
    estimate = max((capacity && capacity.estimated_reps) || 1, 1)

    selected
    |> Enum.map(&(&1.target_reps / max(estimate * (&1.duration_min / 20), 1)))
    |> Enum.sum()
  end

  defp fatigue_cost(selected) do
    selected
    |> Enum.map(fn session ->
      case session.suggestion_kind do
        :maintenance -> 0.5
        :safe_progress -> 0.8
        :recommended -> 1.0
        :stretch -> 1.8
        _ -> 1.0
      end
    end)
    |> Enum.sum()
  end

  defp plan_risk(selected) do
    cond do
      Enum.any?(selected, &(&1.suggestion_kind == :stretch)) -> :high
      length(selected) > 1 -> :normal
      true -> :low
    end
  end

  defp rationale(:preserves_contract, selected),
    do: [
      session_summary(selected),
      "Completes remaining work while preserving the normal 2+2 split."
    ]

  defp rationale(:counts_but_non_standard, selected) do
    [
      session_summary(selected),
      "This completes your 80 min week, but does not preserve the normal 2+2 split."
    ]
  end

  defp rationale(:over_target, selected),
    do: [
      session_summary(selected),
      "Counts toward training history, but puts this week over the 80 min target."
    ]

  defp session_summary([]), do: "No catch-up sessions selected."

  defp session_summary([session]) do
    "Creates 1 × #{session.duration_min} min #{format_type(session.burpee_type)} session: #{session.target_reps} reps."
  end

  defp session_summary(selected) do
    first = List.first(selected)
    same_duration? = Enum.all?(selected, &(&1.duration_min == first.duration_min))
    same_reps? = Enum.all?(selected, &(&1.target_reps == first.target_reps))
    same_type? = Enum.all?(selected, &(&1.burpee_type == first.burpee_type))

    if same_duration? and same_reps? and same_type? do
      "Creates #{length(selected)} × #{first.duration_min} min #{format_type(first.burpee_type)} sessions: #{first.target_reps} reps each."
    else
      "Creates #{length(selected)} catch-up sessions totaling #{Enum.sum(Enum.map(selected, & &1.duration_min))} min."
    end
  end

  defp format_type(:six_count), do: "Six-count"
  defp format_type(:navy_seal), do: "Navy SEAL"
end
