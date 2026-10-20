defmodule BurpeeTrainer.Mcp.AnalyticsGuide do
  @moduledoc "Static analytics semantics, shared with the user guide."
  @path Path.expand("../../../docs/guides/mcp-analytics.md", __DIR__)
  @external_resource @path
  @text File.read!(@path)

  @spec uri() :: String.t()
  def uri, do: "burpee://analytics-guide"

  @spec text() :: String.t()
  def text, do: @text
end
