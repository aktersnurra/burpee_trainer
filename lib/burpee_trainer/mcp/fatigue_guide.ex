defmodule BurpeeTrainer.Mcp.FatigueGuide do
  @moduledoc "What a camera session's fatigue, sets and slack mean, shared with the user guide."
  @path Path.expand("../../../docs/guides/mcp-fatigue.md", __DIR__)
  @external_resource @path
  @text File.read!(@path)

  @spec uri() :: String.t()
  def uri, do: "burpee://fatigue-guide"

  @spec text() :: String.t()
  def text, do: @text
end
