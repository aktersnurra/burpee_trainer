defmodule BurpeeTrainer.Mood do
  @moduledoc """
  Refined workout mood value.
  """

  @type t :: -1 | 0 | 1
  @type error :: {:invalid_mood, term()}

  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(value) when value in [-1, 0, 1], do: {:ok, value}

  def parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {mood, ""} when mood in [-1, 0, 1] -> {:ok, mood}
      _ -> {:error, {:invalid_mood, value}}
    end
  end

  def parse(value), do: {:error, {:invalid_mood, value}}
end
