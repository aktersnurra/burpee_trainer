defmodule BurpeeTrainer.Planning.Compiler do
  @moduledoc "Compiles verified planning drafts to executable workout plans."

  alias BurpeeTrainer.Planning.{Draft, TimelineItem}
  alias BurpeeTrainer.Workouts.{Block, PlanStep, Set, WorkoutPlan}

  @spec to_workout_plan(Draft.t(), keyword()) :: {:ok, WorkoutPlan.t()} | {:error, term()}
  def to_workout_plan(%Draft{} = draft, opts \\ []) do
    name = Keyword.get(opts, :name, "Draft workout")

    timeline_items = Enum.reject(draft.timeline, &match?(%TimelineItem.StandaloneRest{}, &1))

    blocks =
      timeline_items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, position} -> block_from_item(item, position) end)

    steps =
      draft.timeline
      |> Enum.reduce({[], 0}, fn
        %TimelineItem.StandaloneRest{} = item, {steps, block_position} ->
          {[step_from_rest(item, length(steps) + 1) | steps], block_position}

        item, {steps, block_position} ->
          next_block_position = block_position + 1

          {[step_from_block(item, length(steps) + 1, next_block_position) | steps],
           next_block_position}
      end)
      |> elem(0)
      |> Enum.reverse()

    {:ok,
     %WorkoutPlan{
       name: name,
       burpee_type: draft.goal.burpee_type,
       target_duration_min: round(draft.goal.duration_sec / 60),
       burpee_count_target: draft.goal.target_reps,
       sec_per_burpee: average_burpee_duration(draft.timeline),
       pacing_style: draft.goal.style,
       additional_rests: "[]",
       plan_solver_metadata: %{
         "source" => "planning_draft",
         "draft_status" => Atom.to_string(draft.status),
         "generator" => draft.metadata[:generator]
       },
       blocks: blocks,
       steps: steps
     }}
  end

  defp block_from_item(%TimelineItem.EvenUnit{} = item, position) do
    %Block{
      position: position,
      repeat_count: 1,
      sets: [
        %Set{
          position: 1,
          burpee_count: item.reps,
          sec_per_rep: item.rep_interval_sec,
          sec_per_burpee: item.burpee_duration_sec,
          end_of_set_rest: 0
        }
      ]
    }
  end

  defp block_from_item(%TimelineItem.UnbrokenGroup{} = item, position) do
    %Block{
      position: position,
      repeat_count: 1,
      sets: [
        %Set{
          position: 1,
          burpee_count: item.reps,
          sec_per_rep: item.burpee_duration_sec,
          sec_per_burpee: item.burpee_duration_sec,
          end_of_set_rest: item.rest_after_sec
        }
      ]
    }
  end

  defp block_from_item(%TimelineItem.MeaningfulPattern{} = item, position) do
    sets =
      item.pattern
      |> Enum.with_index(1)
      |> Enum.map(fn {reps, set_position} ->
        %Set{
          position: set_position,
          burpee_count: reps,
          sec_per_rep: 1.0,
          sec_per_burpee: 1.0,
          end_of_set_rest: 0
        }
      end)

    %Block{position: position, repeat_count: item.repeat_count, sets: sets}
  end

  defp step_from_rest(%TimelineItem.StandaloneRest{} = item, position) do
    %PlanStep{position: position, kind: :rest, rest_sec: item.duration_sec}
  end

  defp step_from_block(%TimelineItem.MeaningfulPattern{} = item, position, block_position) do
    %PlanStep{
      position: position,
      kind: :block_run,
      block_position: block_position,
      repeat_count: item.repeat_count
    }
  end

  defp step_from_block(_item, position, block_position) do
    %PlanStep{
      position: position,
      kind: :block_run,
      block_position: block_position,
      repeat_count: 1
    }
  end

  defp average_burpee_duration(timeline) do
    durations =
      timeline
      |> Enum.flat_map(fn
        %TimelineItem.EvenUnit{burpee_duration_sec: duration} -> [duration]
        %TimelineItem.UnbrokenGroup{burpee_duration_sec: duration} -> [duration]
        _ -> []
      end)

    case durations do
      [] -> nil
      [_ | _] -> Enum.sum(durations) / length(durations)
    end
  end
end
