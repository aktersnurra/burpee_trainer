defmodule BurpeeTrainer.PrescriptionGraph do
  @moduledoc """
  Builds the execution graph used by the plan editor prescription timeline.

  The source workout model describes authored structure: blocks, sets, repeats,
  and additional rests. The graph describes what the athlete experiences in
  order: block runs, inserted rests, and finish.
  """

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defmodule Graph do
    @enforce_keys [:nodes]
    defstruct [:nodes]
  end

  defmodule StartNode do
    @enforce_keys [:kind, :id, :starts_at_sec]
    defstruct [:kind, :id, :starts_at_sec]
  end

  defmodule BlockRunNode do
    @enforce_keys [
      :kind,
      :id,
      :source_block_index,
      :repeat_from,
      :repeat_to,
      :repeat_count,
      :starts_at_sec,
      :ends_at_sec,
      :block
    ]
    defstruct [
      :kind,
      :id,
      :source_block_index,
      :repeat_from,
      :repeat_to,
      :repeat_count,
      :starts_at_sec,
      :ends_at_sec,
      :block
    ]
  end

  defmodule RestNode do
    @enforce_keys [:kind, :id, :source_rest_index, :starts_at_sec, :duration_sec]
    defstruct [:kind, :id, :source_rest_index, :starts_at_sec, :duration_sec]
  end

  defmodule FinishNode do
    @enforce_keys [:kind, :id, :starts_at_sec]
    defstruct [:kind, :id, :starts_at_sec]
  end

  @type additional_rest :: %{required(:target_min) => integer(), required(:rest_sec) => integer()}

  @spec build(WorkoutPlan.t(), [additional_rest()], number()) :: Graph.t()
  def build(%WorkoutPlan{} = plan, additional_rests, finish_sec) do
    rest_nodes =
      additional_rests
      |> Enum.with_index()
      |> Enum.map(fn {rest, index} ->
        %RestNode{
          kind: :rest,
          id: {:additional_rest, index},
          source_rest_index: index,
          starts_at_sec: rest.target_min * 60,
          duration_sec: rest.rest_sec
        }
      end)

    {block_nodes, execution_finish_sec} =
      plan.blocks
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index()
      |> Enum.map_reduce(0.0, fn {block, block_index}, elapsed ->
        {nodes, elapsed} = block_run_nodes(block, block_index, elapsed, rest_nodes)
        {nodes, elapsed}
      end)

    finish_sec = max(finish_sec, execution_finish_sec)

    body_nodes =
      (List.flatten(block_nodes) ++ rest_nodes)
      |> Enum.sort_by(fn node -> {node.starts_at_sec, node_order(node)} end)

    %Graph{
      nodes: [
        %StartNode{kind: :start, id: :start, starts_at_sec: 0.0}
        | body_nodes ++ [%FinishNode{kind: :finish, id: :finish, starts_at_sec: finish_sec}]
      ]
    }
  end

  defp block_run_nodes(%Block{} = block, block_index, starts_at_sec, rest_nodes) do
    units = block_execution_units(block, starts_at_sec)
    ends_at_sec = units |> List.last() |> Map.fetch!(:ends_at_sec)

    split_rests =
      rest_nodes
      |> Enum.filter(fn rest ->
        rest.starts_at_sec > starts_at_sec and rest.starts_at_sec < ends_at_sec
      end)
      |> Enum.sort_by(& &1.starts_at_sec)

    {nodes, remaining_units, delay} =
      Enum.reduce(split_rests, {[], units, 0}, fn rest, {nodes, remaining_units, delay} ->
        rest_at = rest.starts_at_sec - delay

        {before_units, after_units} =
          Enum.split_while(remaining_units, &(&1.ends_at_sec <= rest_at))

        nodes =
          if before_units == [] do
            nodes
          else
            [block_run_node(block, block_index, before_units, delay) | nodes]
          end

        {nodes, after_units, delay + rest.duration_sec}
      end)

    nodes =
      if remaining_units == [] do
        nodes
      else
        [block_run_node(block, block_index, remaining_units, delay) | nodes]
      end

    {Enum.reverse(nodes), ends_at_sec + delay}
  end

  defp block_run_node(block, block_index, units, delay) do
    first = List.first(units)
    last = List.last(units)
    repeat_from = first.repeat_index
    repeat_to = last.repeat_index

    %BlockRunNode{
      kind: :block_run,
      id: {:block_run, block_index, repeat_from, first.set_position},
      source_block_index: block_index,
      repeat_from: repeat_from,
      repeat_to: repeat_to,
      repeat_count: repeat_to - repeat_from + 1,
      starts_at_sec: first.starts_at_sec + delay,
      ends_at_sec: last.ends_at_sec + delay,
      block: block_segment(block, units)
    }
  end

  defp block_execution_units(%Block{} = block, starts_at_sec) do
    sets = Enum.sort_by(block.sets || [], & &1.position)

    1..(block.repeat_count || 1)
    |> Enum.flat_map(fn repeat_index ->
      Enum.map(sets, fn set -> {repeat_index, set} end)
    end)
    |> Enum.map_reduce(starts_at_sec, fn {repeat_index, set}, elapsed ->
      duration = set_duration(set)

      unit = %{
        repeat_index: repeat_index,
        set_position: set.position,
        starts_at_sec: elapsed,
        ends_at_sec: elapsed + duration
      }

      {unit, elapsed + duration}
    end)
    |> elem(0)
  end

  defp block_segment(%Block{} = block, units) do
    positions = units |> Enum.map(& &1.set_position) |> MapSet.new()

    sets =
      block.sets
      |> Enum.filter(&MapSet.member?(positions, &1.position))
      |> Enum.sort_by(& &1.position)

    %{block | sets: sets}
  end

  defp set_duration(%Set{} = set) do
    (set.burpee_count || 0) * (set.sec_per_rep || 0.0) + (set.end_of_set_rest || 0)
  end

  defp node_order(%RestNode{}), do: 1
  defp node_order(%BlockRunNode{}), do: 0
  defp node_order(_), do: 2
end
