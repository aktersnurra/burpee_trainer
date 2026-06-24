defmodule BurpeeTrainer.PlanPresentation do
  @moduledoc """
  Normalizes solver/persistence atoms into a user-facing workout outline.

  Solver output can contain many blocks and rest steps because those are useful
  persistence/editing atoms. This module collapses them into logical workout
  blocks and set ranges for display.
  """

  alias BurpeeTrainer.Workouts.{Block, PlanStep, Set, WorkoutPlan}

  @type outline :: %{
          summary: String.t(),
          blocks: [map]
        }

  @spec outline(WorkoutPlan.t()) :: outline
  def outline(%WorkoutPlan{plan_solver_metadata: metadata} = plan) when is_map(metadata) do
    if metadata_value(metadata, :solver_version) == 3 and
         is_list(metadata_value(metadata, :blocks)) do
      outline_from_prescription_metadata(plan, metadata)
    else
      outline_from_persisted_atoms(plan)
    end
  end

  def outline(%WorkoutPlan{} = plan), do: outline_from_persisted_atoms(plan)

  defp outline_from_persisted_atoms(%WorkoutPlan{} = plan) do
    set_atoms = expand_sets(plan)
    default_recovery_sec = standard_recovery(set_atoms)
    rows = range_rows(set_atoms)

    %{
      summary: summary(plan, set_atoms),
      blocks: [
        %{
          title: "Block 1",
          set_count: length(set_atoms),
          total_reps: Enum.reduce(set_atoms, 0, &(&1.reps + &2)),
          reps_per_set: common_value(set_atoms, :reps),
          sec_per_rep: common_value(set_atoms, :sec_per_rep),
          sec_per_burpee: common_value(set_atoms, :sec_per_burpee),
          pacing_style: plan.pacing_style,
          default_recovery_sec: default_recovery_sec,
          default_recovery_label: recovery_label(default_recovery_sec, default_recovery_sec),
          rows: rows
        }
      ]
    }
  end

  defp outline_from_prescription_metadata(%WorkoutPlan{} = plan, metadata) do
    set_atoms = expand_metadata_sets(plan, metadata)

    default_recovery_sec =
      metadata_value(metadata, :normal_recovery_sec) || standard_recovery(set_atoms)

    rows = range_rows(set_atoms)
    structure_key = metadata_value(metadata, :structure_key) || "Block 1"

    %{
      summary: summary(plan, set_atoms),
      blocks: [
        %{
          title: structure_title(structure_key),
          set_count: length(set_atoms),
          total_reps: Enum.reduce(set_atoms, 0, &(&1.reps + &2)),
          reps_per_set: common_value(set_atoms, :reps),
          sec_per_rep: common_value(set_atoms, :sec_per_rep),
          sec_per_burpee: common_value(set_atoms, :sec_per_burpee),
          pacing_style: plan.pacing_style,
          default_recovery_sec: default_recovery_sec,
          default_recovery_label: recovery_label(default_recovery_sec, default_recovery_sec),
          rows: rows
        }
      ]
    }
  end

  defp expand_metadata_sets(%WorkoutPlan{} = plan, metadata) do
    blocks = metadata_value(metadata, :blocks) || []
    normal_recovery_sec = metadata_value(metadata, :normal_recovery_sec) || 0

    reset_by_set =
      metadata
      |> metadata_value(:auto_resets)
      |> List.wrap()
      |> Map.new(fn reset ->
        {metadata_value(reset, :after_set), metadata_value(reset, :duration_sec)}
      end)

    sec_per_rep = metadata_value(metadata, :sec_per_rep) || plan.sec_per_burpee || 0.0
    sec_per_burpee = plan.sec_per_burpee || sec_per_rep

    set_pattern =
      blocks
      |> Enum.flat_map(fn block ->
        repeat = metadata_value(block, :repeat) || 1
        motif = metadata_value(block, :motif) || []
        List.duplicate(motif, repeat) |> List.flatten()
      end)

    set_count = length(set_pattern)

    set_pattern
    |> Enum.with_index(1)
    |> Enum.map(fn {reps, set_index} ->
      recovery_sec =
        cond do
          set_index == set_count -> 0
          Map.has_key?(reset_by_set, set_index) -> Map.fetch!(reset_by_set, set_index)
          true -> normal_recovery_sec
        end

      %{
        set_index: set_index,
        reps: reps,
        sec_per_rep: sec_per_rep,
        sec_per_burpee: sec_per_burpee,
        recovery_sec: recovery_sec
      }
    end)
  end

  defp structure_title(structure_key) when is_binary(structure_key) do
    structure_key
    |> String.split("|")
    |> Enum.map(&String.replace(&1, "x", " × "))
    |> Enum.join(" · ")
  end

  defp structure_title(_structure_key), do: "Block 1"

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp expand_sets(%WorkoutPlan{} = plan) do
    blocks_by_position = Map.new(plan.blocks || [], &{&1.position, &1})
    steps = normalized_steps(plan)

    {sets, _last_index} =
      Enum.reduce(steps, {[], 0}, fn
        %PlanStep{kind: :block_run} = step, {sets, next_index} ->
          block = Map.fetch!(blocks_by_position, step.block_position)

          expanded =
            expand_block_run(block, step.repeat_count || block.repeat_count || 1, next_index)

          {sets ++ expanded, next_index + length(expanded)}

        %PlanStep{kind: :rest}, {[], next_index} ->
          {[], next_index}

        %PlanStep{kind: :rest, rest_sec: rest_sec}, {sets, next_index} ->
          {List.update_at(sets, -1, fn set ->
             %{set | recovery_sec: set.recovery_sec + rest_sec}
           end), next_index}
      end)

    sets
  end

  defp normalized_steps(%WorkoutPlan{steps: steps}) when is_list(steps) and steps != [] do
    Enum.sort_by(steps, & &1.position)
  end

  defp normalized_steps(%WorkoutPlan{blocks: blocks}) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn %Block{} = block ->
      %PlanStep{
        kind: :block_run,
        block_position: block.position,
        repeat_count: block.repeat_count
      }
    end)
  end

  defp expand_block_run(%Block{} = block, repeat_count, next_index) do
    sets = Enum.sort_by(block.sets || [], & &1.position)

    for repeat <- 1..repeat_count, {set, set_offset} <- Enum.with_index(sets) do
      set_index = next_index + (repeat - 1) * length(sets) + set_offset + 1
      set_atom(set, set_index)
    end
  end

  defp set_atom(%Set{} = set, set_index) do
    %{
      set_index: set_index,
      reps: set.burpee_count,
      sec_per_rep: set.sec_per_rep,
      sec_per_burpee: set.sec_per_burpee,
      recovery_sec: set.end_of_set_rest || 0
    }
  end

  defp range_rows([]), do: []

  defp range_rows(sets) do
    standard_recovery = standard_recovery(sets)

    sets
    |> Enum.chunk_by(&row_key(&1, standard_recovery))
    |> Enum.map(fn group ->
      first = hd(group)
      last = List.last(group)
      recovery_sec = display_recovery(first.recovery_sec, standard_recovery)
      recovery_label = recovery_label(recovery_sec, standard_recovery)

      %{
        from_set: first.set_index,
        to_set: last.set_index,
        reps: first.reps,
        sec_per_rep: first.sec_per_rep,
        sec_per_burpee: first.sec_per_burpee,
        recovery_sec: recovery_sec,
        recovery_label: recovery_label,
        set_count: length(group)
      }
    end)
  end

  defp standard_recovery(sets) do
    sets
    |> Enum.drop(-1)
    |> Enum.map(& &1.recovery_sec)
    |> Enum.reject(&(&1 == 0))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_recovery, count} -> count end, fn -> {0, 0} end)
    |> elem(0)
  end

  defp display_recovery(0, _standard), do: 0
  defp display_recovery(recovery, standard) when abs(recovery - standard) <= 1, do: standard
  defp display_recovery(recovery, _standard), do: recovery

  defp recovery_label(0, _standard), do: "No recovery"
  defp recovery_label(recovery, _standard), do: "#{recovery}s recovery"

  defp row_key(set, standard_recovery),
    do:
      {set.reps, Float.round(set.sec_per_rep * 1.0, 3), Float.round(set.sec_per_burpee * 1.0, 3),
       display_recovery(set.recovery_sec, standard_recovery)}

  defp common_value([], _field), do: nil

  defp common_value(items, field) do
    values = items |> Enum.map(&Map.fetch!(&1, field)) |> Enum.uniq()
    if length(values) == 1, do: hd(values), else: nil
  end

  defp summary(%WorkoutPlan{} = plan, sets) do
    duration_sec = (plan.target_duration_min || 0) * 60
    reps = Enum.reduce(sets, 0, &(&1.reps + &2))
    set_count = length(sets)

    "#{format_duration(duration_sec)} · #{reps} reps · #{set_count} sets"
  end

  defp format_duration(sec) when is_number(sec) do
    sec = round(sec)
    min = div(sec, 60)
    rem_sec = rem(sec, 60)
    "#{min}:#{String.pad_leading(Integer.to_string(rem_sec), 2, "0")}"
  end
end
