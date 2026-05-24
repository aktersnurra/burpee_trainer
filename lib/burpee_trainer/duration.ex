defmodule BurpeeTrainer.Duration do
  @moduledoc """
  Duration parsing and conversion helpers.
  """

  @type seconds :: non_neg_integer()
  @type error :: {:invalid_duration_min, term()}

  @spec parse_minutes_to_seconds(term()) :: {:ok, seconds()} | {:error, error()}
  def parse_minutes_to_seconds(value) when is_binary(value) do
    case Float.parse(value) do
      {minutes, ""} when minutes >= 0 -> {:ok, round(minutes * 60)}
      {minutes, _rest} when minutes >= 0 -> {:ok, round(minutes * 60)}
      _ -> {:error, {:invalid_duration_min, value}}
    end
  end

  def parse_minutes_to_seconds(value) when is_number(value) and value >= 0 do
    {:ok, round(value * 60)}
  end

  def parse_minutes_to_seconds(value), do: {:error, {:invalid_duration_min, value}}
end
