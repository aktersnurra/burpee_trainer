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

    {block_nodes, _elapsed} =
      plan.blocks
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index()
      |> Enum.map_reduce(0.0, fn {block, block_index}, elapsed ->
        {nodes, elapsed} = block_run_nodes(block, block_index, elapsed, rest_nodes)
        {nodes, elapsed}
      end)

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
    repeat_count = block.repeat_count || 1
    repeat_duration = block_repeat_duration(block)
    total_duration = repeat_count * repeat_duration
    ends_at_sec = starts_at_sec + total_duration

    split_rests =
      rest_nodes
      |> Enum.filter(fn rest ->
        rest.starts_at_sec > starts_at_sec and rest.starts_at_sec < ends_at_sec
      end)
      |> Enum.sort_by(& &1.starts_at_sec)

    {nodes, repeat_cursor, time_cursor} =
      Enum.reduce(split_rests, {[], 1, starts_at_sec}, fn rest,
                                                          {nodes, repeat_cursor, time_cursor} ->
        repeats_before_rest =
          rest.starts_at_sec
          |> Kernel.-(time_cursor)
          |> Kernel./(repeat_duration)
          |> floor()
          |> max(0)

        repeat_to = min(repeat_count, repeat_cursor + repeats_before_rest - 1)

        nodes =
          if repeat_to >= repeat_cursor do
            [
              block_run_node(
                block,
                block_index,
                repeat_cursor,
                repeat_to,
                time_cursor,
                rest.starts_at_sec
              )
              | nodes
            ]
          else
            nodes
          end

        next_repeat = repeat_to + 1
        next_time = rest.starts_at_sec + rest.duration_sec
        {nodes, next_repeat, next_time}
      end)

    nodes =
      if repeat_cursor <= repeat_count do
        [
          block_run_node(
            block,
            block_index,
            repeat_cursor,
            repeat_count,
            time_cursor,
            ends_at_sec + rest_delay_inside(starts_at_sec, ends_at_sec, rest_nodes)
          )
          | nodes
        ]
      else
        nodes
      end

    {Enum.reverse(nodes),
     starts_at_sec + total_duration + rest_delay_inside(starts_at_sec, ends_at_sec, rest_nodes)}
  end

  defp block_run_node(block, block_index, repeat_from, repeat_to, starts_at_sec, ends_at_sec) do
    %BlockRunNode{
      kind: :block_run,
      id: {:block_run, block_index, repeat_from},
      source_block_index: block_index,
      repeat_from: repeat_from,
      repeat_to: repeat_to,
      repeat_count: repeat_to - repeat_from + 1,
      starts_at_sec: starts_at_sec,
      ends_at_sec: ends_at_sec,
      block: block
    }
  end

  defp block_repeat_duration(%Block{sets: sets}) do
    sets
    |> Enum.reduce(0.0, fn %Set{} = set, total ->
      total + (set.burpee_count || 0) * (set.sec_per_rep || 0.0) + (set.end_of_set_rest || 0)
    end)
  end

  defp rest_delay_inside(starts_at_sec, ends_at_sec, rest_nodes) do
    rest_nodes
    |> Enum.filter(fn rest ->
      rest.starts_at_sec > starts_at_sec and rest.starts_at_sec < ends_at_sec
    end)
    |> Enum.reduce(0, fn rest, total -> total + rest.duration_sec end)
  end

  defp node_order(%RestNode{}), do: 1
  defp node_order(%BlockRunNode{}), do: 0
  defp node_order(_), do: 2
end
