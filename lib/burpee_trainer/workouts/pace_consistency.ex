defmodule BurpeeTrainer.Workouts.PaceConsistency do
  @moduledoc """
  Computes pace consistency from rep completion timestamps.

  Uses population standard deviation of inter-rep intervals. Returns nil for
  fewer than three reps because two intervals are too little signal for a useful
  consistency score.
  """

  @spec score([non_neg_integer()]) :: float() | nil
  def score(cadence_ms) when is_list(cadence_ms) and length(cadence_ms) >= 3 do
    intervals = intervals(cadence_ms)
    mean = Enum.sum(intervals) / length(intervals)

    if mean <= 0 do
      nil
    else
      variance =
        intervals
        |> Enum.map(&:math.pow(&1 - mean, 2))
        |> Enum.sum()
        |> Kernel./(length(intervals))

      cv = :math.sqrt(variance) / mean
      clamp(1.0 - cv)
    end
  end

  def score(_), do: nil

  defp intervals(cadence_ms) do
    cadence_ms
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
  end

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: Float.round(value, 6)
end
