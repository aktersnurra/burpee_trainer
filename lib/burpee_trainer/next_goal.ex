defmodule BurpeeTrainer.NextGoal do
  @moduledoc """
  The goal the coach suggests next, without a model call: the next level landmark above
  the best for that burpee type, in 20 minutes, six weeks from today. Above the last
  landmark it is ten percent more, rounded up to five.
  """

  alias BurpeeTrainer.Levels

  @duration_sec 1200
  @weeks 6

  @spec for_best(:six_count | :navy_seal, non_neg_integer(), Date.t()) :: %{
          burpee_type: :six_count | :navy_seal,
          burpee_count_target: pos_integer(),
          duration_sec_target: pos_integer(),
          date_target: Date.t()
        }
  def for_best(type, best, %Date{} = today) when type in [:six_count, :navy_seal] do
    %{
      burpee_type: type,
      burpee_count_target: target(type, best),
      duration_sec_target: @duration_sec,
      date_target: Date.add(today, @weeks * 7)
    }
  end

  defp target(type, best) do
    Levels.all_levels()
    |> Enum.map(&Levels.threshold(&1, type))
    # The floor landmark (one rep) is where everyone starts, not a goal.
    |> Enum.reject(&(&1 <= 1))
    |> Enum.sort()
    |> Enum.find(&(&1 > best))
    |> case do
      nil -> ceil_to_five(best * 1.1)
      landmark -> landmark
    end
  end

  defp ceil_to_five(value), do: (ceil(value / 5) * 5) |> max(5) |> trunc()
end
