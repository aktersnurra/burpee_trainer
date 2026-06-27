defmodule BurpeeTrainerWeb.PlansLive.Edit.Presentation do
  @moduledoc """
  Presentation-only summaries for the plan creator/editor.

  This module keeps wording, block-row expansion, and structure-map data out
  of the LiveView process. It does not change solver behavior or persistence.
  """

  alias BurpeeTrainer.Workouts.{Block, WorkoutPlan}
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
    total_reps = derived_value(derived, :burpee_count) || Enum.sum(Enum.map(rows, & &1.reps))
    duration_min = plan.target_duration_min || duration_min_from_derived(derived)

    %{
      title: "#{duration_min} min #{type_label(plan.burpee_type)}",
      stats: "#{total_reps} reps · #{length(rows)} #{plural(length(rows), "block")}",
      structure: structure_sentence(plan, rows),
      feel: expected_feel(plan),
      block_rows: rows,
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
  end

  def block_rows(%WorkoutPlan{blocks: blocks}, locked_indexes) when is_list(blocks) do
    blocks
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, source_index} -> expand_block(block, source_index) end)
    |> decorate_rows(locked_indexes)
  end

  def block_rows(_plan, _locked_indexes), do: []

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
        label: "#{first.reps} reps · #{Fmt.duration_sec(first.rest_sec)} rest"
      }
    end)
  end

  defp decorate_rows(rows, locked_indexes) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      locked? = MapSet.member?(locked_indexes, row.source_block_index)

      row
      |> Map.put(:index, index)
      |> Map.put(:title, "Block #{index + 1}")
      |> Map.put(:locked?, locked?)
      |> Map.put(:lock_label, if(locked?, do: "Locked by you", else: nil))
    end)
  end

  defp expand_block(%Block{} = block, source_index, repeat_override \\ nil) do
    repeat_count = max(repeat_override || block.repeat_count || 1, 1)
    reps = block_reps(block)
    sec_per_rep = representative_sec_per_rep(block)
    rest_sec = block_rest_sec(block)

    for _repeat <- 1..repeat_count do
      %{
        source_block_index: source_index,
        headline: "Unbroken · #{reps} reps",
        detail:
          "Rep every #{format_sec_per_rep(sec_per_rep)} · #{Fmt.duration_sec(rest_sec)} rest",
        reps: reps,
        sec_per_rep: sec_per_rep,
        rest_sec: rest_sec
      }
    end
  end

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

  defp derived_value(nil, _key), do: nil
  defp derived_value(map, key) when is_map(map), do: Map.get(map, key)

  defp duration_min_from_derived(%{duration_sec: seconds}) when is_number(seconds),
    do: round(seconds / 60)

  defp duration_min_from_derived(_derived), do: 20

  defp structure_sentence(%WorkoutPlan{pacing_style: :unbroken}, _rows),
    do: "Mostly unbroken, rests increase gradually"

  defp structure_sentence(_plan, rows) when length(rows) > 1,
    do: "Steady blocks with planned rest"

  defp structure_sentence(_plan, _rows), do: "Simple steady structure"

  defp expected_feel(%WorkoutPlan{pacing_style: :unbroken}),
    do: "Expected feel: controlled, not all-out"

  defp expected_feel(_plan), do: "Expected feel: steady and repeatable"

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
