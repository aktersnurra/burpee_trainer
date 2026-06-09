defmodule BurpeeTrainer.PlanEditor.Structure do
  @moduledoc """
  User-editable workout structure as ordered work/rest nodes.

  This is an editor-facing model, not a persistence model. Persistence remains
  `WorkoutPlan.blocks + WorkoutPlan.steps`; explicit additional rests are always
  represented as `RestNode`s, never folded into set recovery.
  """

  alias BurpeeTrainer.PlanNotation
  alias BurpeeTrainer.PlanEditor.Structure.{RestNode, WorkNode}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @enforce_keys [:nodes]
  defstruct [:nodes]

  @type item :: WorkNode.t() | RestNode.t()
  @type t :: %__MODULE__{nodes: [item()]}

  @spec from_plan(WorkoutPlan.t()) :: t()
  def from_plan(%WorkoutPlan{} = plan) do
    blocks = plan.blocks |> loaded() |> Enum.sort_by(& &1.position)
    blocks_by_position = Map.new(blocks, &{&1.position, &1})
    steps = plan.steps |> loaded() |> Enum.sort_by(& &1.position)

    nodes =
      if steps == [] do
        Enum.map(blocks, &work_node(&1, &1.repeat_count || 1))
      else
        Enum.flat_map(steps, fn
          %{kind: :block_run, block_position: block_position, repeat_count: repeat_count} ->
            case Map.fetch(blocks_by_position, block_position) do
              {:ok, block} -> [work_node(block, repeat_count || 1)]
              :error -> []
            end

          %{kind: :rest, rest_sec: rest_sec} ->
            [%RestNode{rest_sec: rest_sec || 30}]
        end)
      end

    %__MODULE__{nodes: merge_adjacent_work(nodes)}
  end

  @spec notation(t()) :: String.t()
  def notation(%__MODULE__{nodes: nodes}), do: PlanNotation.from_nodes(nodes)

  @spec total_reps(t()) :: non_neg_integer()
  def total_reps(%__MODULE__{nodes: nodes}) do
    Enum.reduce(nodes, 0, fn
      %WorkNode{} = node, total -> total + node.repeat_count * Enum.sum(node.set_pattern)
      %RestNode{}, total -> total
    end)
  end

  @spec explicit_rest_sec(t()) :: non_neg_integer()
  def explicit_rest_sec(%__MODULE__{nodes: nodes}) do
    Enum.reduce(nodes, 0, fn
      %RestNode{rest_sec: rest_sec}, total -> total + rest_sec
      %WorkNode{}, total -> total
    end)
  end

  @spec update_rest(t(), non_neg_integer(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def update_rest(%__MODULE__{} = structure, index, rest_sec)
      when is_integer(rest_sec) and rest_sec > 0 do
    update_node(structure, index, RestNode, fn _node -> %RestNode{rest_sec: rest_sec} end)
  end

  @spec update_work(t(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def update_work(%__MODULE__{} = structure, index, attrs) do
    update_node(structure, index, WorkNode, fn node ->
      repeat_count = Keyword.get(attrs, :repeat_count, node.repeat_count)
      set_pattern = Keyword.get(attrs, :set_pattern, node.set_pattern)
      %WorkNode{repeat_count: repeat_count, set_pattern: set_pattern}
    end)
  end

  defp update_node(%__MODULE__{nodes: nodes} = structure, index, module, fun) do
    case Enum.at(nodes, index) do
      %^module{} = node -> {:ok, %{structure | nodes: List.replace_at(nodes, index, fun.(node))}}
      nil -> {:error, :node_not_found}
      _other -> {:error, :wrong_node_kind}
    end
  end

  defp work_node(block, repeat_count) do
    %WorkNode{
      repeat_count: repeat_count,
      set_pattern:
        block.sets
        |> loaded()
        |> Enum.sort_by(& &1.position)
        |> Enum.map(&(&1.burpee_count || 0))
    }
  end

  defp merge_adjacent_work(nodes) do
    Enum.reduce(nodes, [], fn node, acc ->
      case {List.last(acc), node} do
        {%WorkNode{set_pattern: pattern} = previous, %WorkNode{set_pattern: pattern}} ->
          List.replace_at(acc, -1, %WorkNode{
            previous
            | repeat_count: previous.repeat_count + node.repeat_count
          })

        _ ->
          acc ++ [node]
      end
    end)
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(items) when is_list(items), do: items
  defp loaded(_items), do: []
end
