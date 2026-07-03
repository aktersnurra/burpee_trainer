defmodule BurpeeTrainerWeb.PlansLive.Edit.Presentation do
  @moduledoc """
  Presentation-only summaries for the plan creator/editor.

  This module keeps wording, block-row expansion, and structure-map data out
  of the LiveView process. It does not change solver behavior or persistence.
  """

  alias BurpeeTrainer.PlanEditor.Block
  alias BurpeeTrainer.Workouts.WorkoutPlan
  alias BurpeeTrainerWeb.Fmt

  @type block_row :: %{
          index: non_neg_integer(),
          source_block_index: non_neg_integer(),
          title: String.t(),
          headline: String.t(),
          detail: String.t(),
          reps: non_neg_integer(),
          sec_per_rep: number() | nil,
          rest_sec: non_neg_integer(),
          locked?: boolean(),
          lock_label: String.t() | nil
        }

  @spec contract(WorkoutPlan.t(), map() | nil) :: map()
  def contract(%WorkoutPlan{} = plan, derived \\ nil) do
    rows = block_rows(plan)
    total_reps = derived_value(derived, :burpee_count) || display_rep_count(rows)
    block_count = display_block_count(rows)
    duration_min = plan.target_duration_min || duration_min_from_derived(derived)

    %{
      title: "#{Fmt.duration_sec(duration_min * 60)} · #{type_label(plan.burpee_type)}",
      stats:
        "#{total_reps} reps · #{style_label(plan.pacing_style)} · #{block_count} #{plural(block_count, "block")}",
      structure: structure_sentence(plan, rows),
      feel: expected_feel(plan),
      pace_label: pace_bias_label(plan),
      shape_label: load_shape_label(plan),
      block_rows: rows,
      structure_rows: structure_rows(plan, rows),
      structure_map: structure_map(rows),
      structure_groups: structure_groups(rows)
    }
  end

  @spec block_rows(WorkoutPlan.t(), MapSet.t()) :: [block_row()]
  def block_rows(plan, locked_indexes \\ MapSet.new())

  def block_rows(%WorkoutPlan{steps: steps, blocks: blocks}, locked_indexes)
      when is_list(steps) and steps != [] and is_list(blocks) do
    blocks_by_position =
      blocks
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.with_index()
      |> Map.new(fn {block, source_index} -> {block.position, {block, source_index}} end)

    steps
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.flat_map(fn
      %{kind: :block_run, block_position: block_position, repeat_count: repeat_count} ->
        case Map.fetch(blocks_by_position, block_position) do
          {:ok, {block, source_index}} -> expand_block(block, source_index, repeat_count)
          :error -> []
        end

      _step ->
        []
    end)
    |> decorate_rows(locked_indexes)
    |> group_block_rows()
  end

  def block_rows(%WorkoutPlan{blocks: blocks}, locked_indexes) when is_list(blocks) do
    blocks
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, source_index} -> expand_block(block, source_index) end)
    |> decorate_rows(locked_indexes)
    |> group_block_rows()
  end

  def block_rows(_plan, _locked_indexes), do: []

  @spec structure_rows(WorkoutPlan.t(), [block_row()]) :: [map()]
  def structure_rows(%WorkoutPlan{steps: steps, blocks: blocks}, block_rows)
      when is_list(steps) and steps != [] and is_list(blocks) do
    locked_indexes =
      block_rows
      |> Enum.filter(& &1.locked?)
      |> Enum.flat_map(&Map.get(&1, :source_block_indices, [&1.source_block_index]))
      |> MapSet.new()

    blocks_by_position =
      blocks
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.with_index()
      |> Map.new(fn {block, source_index} -> {block.position, {block, source_index}} end)

    {rows, _display_index} =
      steps
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.reduce({[], 0}, fn
        %{kind: :block_run, block_position: block_position, repeat_count: repeat_count} = step,
        {rows, display_index} ->
          count = max(repeat_count || 1, 1)

          segment_rows =
            case Map.fetch(blocks_by_position, block_position) do
              {:ok, {block, source_index}} ->
                block
                |> expand_block(source_index, count)
                |> decorate_rows(locked_indexes, display_index)
                |> group_block_rows(false)
                |> Enum.map(fn row ->
                  row
                  |> Map.put(:kind, :block)
                  |> Map.put(:block_position, block_position)
                  |> Map.put(:step_position, step.position)
                end)

              :error ->
                []
            end

          {rows ++ segment_rows, display_index + count}

        %{kind: :rest, rest_sec: rest_sec}, {rows, display_index} ->
          {rows ++ [rest_row(rest_sec || 0)], display_index}

        _step, acc ->
          acc
      end)

    rows
  end

  def structure_rows(_plan, block_rows), do: Enum.map(block_rows, &Map.put(&1, :kind, :block))

  @spec structure_map([block_row()]) :: [map()]
  def structure_map(rows) do
    max_reps = rows |> Enum.map(& &1.reps) |> Enum.max(fn -> 1 end)

    Enum.map(rows, fn row ->
      %{
        label: "#{row.title} · #{row.reps} reps",
        height: max(24, round(row.reps / max(max_reps, 1) * 48)),
        gap: rest_gap(row.rest_sec),
        shade: shade(row.reps, max_reps)
      }
    end)
  end

  @spec structure_groups([block_row()]) :: [map()]
  def structure_groups(rows) do
    rows
    |> Enum.chunk_by(fn row -> {row.reps, rest_bucket(row.rest_sec)} end)
    |> Enum.map(fn chunk ->
      first = hd(chunk)
      last = List.last(chunk)

      %{
        range: range_label(first.index + 1, last.index + 1),
        label: structure_group_label(first)
      }
    end)
  end

  @spec plan_feedback(String.t() | nil, map() | nil, map()) :: map() | nil
  def plan_feedback(solver_error, _derived, plan_input) when is_binary(solver_error) do
    %{
      title: "This cannot fit in #{Fmt.duration_sec(plan_input.target_duration_min * 60)}",
      message: "The locked blocks and rests exceed the duration.",
      actions: ["Show locked blocks", "Unlock all", "Allow longer workout", "Undo"]
    }
  end

  def plan_feedback(nil, %{both_ok: false} = derived, plan_input) do
    target_sec = plan_input.target_duration_min * 60
    duration_sec = round(derived.duration_sec)
    planned_reps = derived.burpee_count
    target_reps = plan_input.burpee_count_target

    cond do
      duration_sec > target_sec ->
        %{
          title: "Workout no longer fits #{Fmt.duration_sec(target_sec)}",
          message: "You are #{Fmt.duration_sec(duration_sec - target_sec)} over.",
          actions: [
            "Balance remaining work",
            "Keep #{Fmt.duration_sec(duration_sec)}",
            "Undo change"
          ]
        }

      duration_sec < target_sec ->
        %{
          title: "Workout ends before #{Fmt.duration_sec(target_sec)}",
          message: "You have #{Fmt.duration_sec(target_sec - duration_sec)} unused.",
          actions: [
            "Add rest at end",
            "Balance remaining work",
            "Keep #{Fmt.duration_sec(duration_sec)}",
            "Undo change"
          ]
        }

      reps_ok?(derived) == false ->
        %{
          title: "Reps do not match target",
          message: "Planned: #{planned_reps}\nTarget: #{target_reps}",
          actions: [
            "Balance remaining work",
            "Update target to #{planned_reps}",
            "Undo change"
          ]
        }

      true ->
        nil
    end
  end

  def plan_feedback(_solver_error, _derived, _plan_input), do: nil

  defp reps_ok?(derived) do
    Map.get(derived, :reps_ok, Map.get(derived, :count_ok))
  end

  defp structure_group_label(%{block_count: count, reps: reps, rest_sec: rest_sec})
       when count > 1 do
    "#{reps} reps each · #{Fmt.duration_sec(rest_sec)} rest"
  end

  defp structure_group_label(%{reps: reps, rest_sec: rest_sec}) do
    "#{reps} reps · #{Fmt.duration_sec(rest_sec)} rest"
  end

  defp rest_row(rest_sec) do
    %{
      kind: :rest,
      index: nil,
      source_block_index: nil,
      title: "Rest",
      headline: "#{Fmt.duration_sec(rest_sec)} recovery",
      detail: "Manual rest between blocks",
      reps: 0,
      sec_per_rep: nil,
      rest_sec: rest_sec,
      locked?: false,
      lock_label: nil
    }
  end

  defp decorate_rows(rows, locked_indexes, start_index \\ 0) do
    rows
    |> Enum.with_index(start_index)
    |> Enum.map(fn {row, index} ->
      locked? = MapSet.member?(locked_indexes, row.source_block_index)

      row
      |> Map.put(:index, index)
      |> Map.put(:title, "Block #{index + 1}")
      |> Map.put(:locked?, locked?)
      |> Map.put(:lock_label, if(locked?, do: "Locked by you", else: nil))
      |> Map.put(:block_count, 1)
      |> Map.put(:source_block_indices, [row.source_block_index])
    end)
  end

  defp group_block_rows(rows, reset_index? \\ true) do
    rows =
      rows
      |> Enum.chunk_by(&group_key/1)
      |> Enum.flat_map(&group_chunk/1)

    if reset_index? do
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> %{row | index: index} end)
    else
      rows
    end
  end

  defp group_key(row) do
    {row.reps, row.sec_per_rep, row.rest_sec, row.locked?, row.lock_label, row.set_signature}
  end

  defp group_chunk([row]), do: [row]

  defp group_chunk(chunk) do
    first = hd(chunk)
    last = List.last(chunk)
    count = length(chunk)

    [
      %{
        first
        | title: "Blocks #{range_label(first.index + 1, last.index + 1)}",
          headline: "#{first.reps} reps each",
          block_count: count,
          source_block_indices: Enum.map(chunk, & &1.source_block_index)
      }
    ]
  end

  defp display_block_count(rows) do
    rows
    |> Enum.map(&Map.get(&1, :block_count, 1))
    |> Enum.sum()
  end

  defp display_rep_count(rows) do
    rows
    |> Enum.map(fn row -> row.reps * Map.get(row, :block_count, 1) end)
    |> Enum.sum()
  end

  defp expand_block(%Block{} = block, source_index, repeat_override \\ nil) do
    repeat_count = max(repeat_override || block.repeat_count || 1, 1)
    reps = block_reps(block)
    sec_per_rep = representative_sec_per_rep(block)
    rest_sec = block_rest_sec(block)
    set_rows = block_set_rows(block)
    set_signature = Enum.map(set_rows, &{&1.burpee_count, &1.sec_per_rep, &1.end_of_set_rest})

    for _repeat <- 1..repeat_count do
      %{
        source_block_index: source_index,
        headline: "#{reps} reps",
        detail:
          "Rep every #{format_sec_per_rep(sec_per_rep)} · #{Fmt.duration_sec(rest_sec)} rest",
        reps: reps,
        sec_per_rep: sec_per_rep,
        rest_sec: rest_sec,
        repeat_count: repeat_count,
        sets: set_rows,
        set_signature: set_signature
      }
    end
  end

  defp block_set_rows(%Block{sets: sets}) when is_list(sets) do
    sets
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index()
    |> Enum.map(fn {set, index} ->
      %{
        index: index,
        burpee_count: set.burpee_count || 0,
        sec_per_rep: set.sec_per_rep,
        end_of_set_rest: set.end_of_set_rest || 0
      }
    end)
  end

  defp block_set_rows(_block), do: []

  defp block_reps(%Block{sets: sets}) when is_list(sets) do
    sets |> Enum.map(&(&1.burpee_count || 0)) |> Enum.sum()
  end

  defp block_reps(_block), do: 0

  defp representative_sec_per_rep(%Block{sets: sets}) when is_list(sets) do
    sets
    |> Enum.sort_by(&(&1.position || 0))
    |> List.first()
    |> case do
      %{sec_per_rep: sec_per_rep} when is_number(sec_per_rep) -> sec_per_rep
      _ -> nil
    end
  end

  defp representative_sec_per_rep(_block), do: nil

  defp block_rest_sec(%Block{sets: sets}) when is_list(sets) do
    sets
    |> Enum.sort_by(&(&1.position || 0))
    |> List.last()
    |> case do
      %{end_of_set_rest: rest} when is_number(rest) -> round(rest)
      _ -> 0
    end
  end

  defp block_rest_sec(_block), do: 0

  defp type_label(:six_count), do: "Six-count"
  defp type_label(:navy_seal), do: "Navy SEAL"
  defp type_label(other), do: Fmt.burpee_type(other)

  defp style_label(:even), do: "Even"
  defp style_label(:unbroken), do: "Unbroken sets"
  defp style_label(_style), do: "workout"

  defp metadata_value(%WorkoutPlan{plan_solver_metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_plan, _key), do: nil

  defp pace_bias_label(plan) do
    case metadata_value(plan, :pace_bias) do
      :slower -> "Slower pace"
      "slower" -> "Slower pace"
      :faster -> "Faster pace"
      "faster" -> "Faster pace"
      _ -> "Balanced pace"
    end
  end

  defp load_shape_label(plan) do
    case metadata_value(plan, :load_shape) do
      :front_loaded -> "Front-loaded"
      "front_loaded" -> "Front-loaded"
      :back_loaded -> "Back-loaded"
      "back_loaded" -> "Back-loaded"
      _ -> "Flat load"
    end
  end

  defp derived_value(nil, _key), do: nil
  defp derived_value(map, key) when is_map(map), do: Map.get(map, key)

  defp duration_min_from_derived(%{duration_sec: seconds}) when is_number(seconds),
    do: round(seconds / 60)

  defp duration_min_from_derived(_derived), do: 20

  defp structure_sentence(%WorkoutPlan{pacing_style: :unbroken}, [first | _rows]) do
    count = Map.get(first, :block_count, 1)

    if count > 1 do
      "#{first.reps} reps each · grouped sets"
    else
      "#{first.reps} reps · unbroken set"
    end
  end

  defp structure_sentence(%WorkoutPlan{pacing_style: :unbroken}, _rows),
    do: "Grouped sets with planned rest"

  defp structure_sentence(_plan, rows) when length(rows) > 1,
    do: "Steady blocks with planned rest"

  defp structure_sentence(_plan, _rows), do: "Simple steady structure"

  defp expected_feel(%WorkoutPlan{pacing_style: :unbroken}),
    do: "Controlled, not all-out"

  defp expected_feel(_plan), do: "Steady and repeatable"

  defp format_sec_per_rep(nil), do: "—"

  defp format_sec_per_rep(value) when is_number(value),
    do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}s"

  defp rest_gap(rest_sec) when rest_sec <= 0, do: 4
  defp rest_gap(rest_sec) when rest_sec < 30, do: 8
  defp rest_gap(rest_sec) when rest_sec < 60, do: 12
  defp rest_gap(_rest_sec), do: 16

  defp rest_bucket(rest_sec) when rest_sec < 30, do: :short
  defp rest_bucket(rest_sec) when rest_sec < 60, do: :medium
  defp rest_bucket(_rest_sec), do: :long

  defp shade(reps, max_reps) when max_reps <= 0 or reps <= 0, do: 0.35
  defp shade(reps, max_reps), do: Float.round(0.35 + reps / max_reps * 0.5, 2)

  defp range_label(from, from), do: Integer.to_string(from)
  defp range_label(from, to), do: "#{from}–#{to}"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
