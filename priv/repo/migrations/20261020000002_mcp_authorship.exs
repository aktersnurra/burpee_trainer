defmodule BurpeeTrainer.Repo.Migrations.McpAuthorship do
  @moduledoc """
  What an MCP client wrote is marked `mcp`, not `claude`: any MCP client can coach
  through `/mcp`. Applies to the slot's `planned_by` and the coach note's `source`.
  """
  use Ecto.Migration

  def up, do: mark("claude", "mcp")
  def down, do: mark("mcp", "claude")

  defp mark(from, to) do
    execute "UPDATE coach_recommendations SET planned_by = '#{to}' WHERE planned_by = '#{from}'"
    execute "UPDATE coach_summaries SET source = '#{to}' WHERE source = '#{from}'"
  end
end
