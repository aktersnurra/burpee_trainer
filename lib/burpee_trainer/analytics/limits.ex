defmodule BurpeeTrainer.Analytics.Limits do
  @moduledoc "Deterministic analytics ceilings, in UTF-8 bytes and monotonic milliseconds."
  def prompt_bytes, do: 4096
  def intent_bytes, do: 512
  def interpretation_bytes, do: 1024
  def sql_bytes, do: 4096
  def context_bytes, do: 65_536
  def narrative_bytes, do: 8192
  def output_bytes, do: 49_152
  def trace_bytes, do: 65_536
  def run_ms, do: 45_000
  def reserve_ms, do: 1000
  def analyst_ms, do: 5000
  def review_ms, do: 3000
  def queries, do: 3
  def analyst_calls, do: 5
  def review_calls, do: 3
  def calls, do: 8

  def usage(map) do
    Map.take(map, ~w(prompt_tokens completion_tokens input_tokens output_tokens cost))
    |> Map.filter(fn {_key, value} -> is_number(value) and value >= 0 end)
  end

  def text?(value, max), do: is_binary(value) and String.valid?(value) and byte_size(value) <= max
end
