defmodule BurpeeTrainer.Mcp.AnalyticsSchema do
  @moduledoc "Static analytics definitions, never snapshot rows."
  def uri, do: "burpee://analytics/schema"
  def text, do: BurpeeTrainer.Analytics.Schema.text()
end
