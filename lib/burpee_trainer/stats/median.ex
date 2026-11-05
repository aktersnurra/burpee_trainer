defmodule BurpeeTrainer.Stats.Median do
  @moduledoc "The median of a list of numbers, unrounded; nil for an empty list."

  @spec of([number()]) :: float() | nil
  def of([]), do: nil

  def of(values) when is_list(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid) / 1,
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end
end
