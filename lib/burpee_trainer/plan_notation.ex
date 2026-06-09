defmodule BurpeeTrainer.PlanNotation do
  @moduledoc "Readable workout notation for Block/Set structures and explicit rests."

  alias BurpeeTrainer.PlanEditor.Structure.{RestNode, WorkNode}

  @spec from_nodes([WorkNode.t() | RestNode.t()]) :: String.t()
  def from_nodes(nodes) do
    nodes
    |> Enum.map(&node_label/1)
    |> Enum.join(" · ")
  end

  defp node_label(%WorkNode{repeat_count: repeat, set_pattern: pattern}) do
    "#{repeat} × [#{Enum.join(pattern, ", ")}]"
  end

  defp node_label(%RestNode{rest_sec: rest_sec}), do: "Rest #{rest_sec}s"
end
