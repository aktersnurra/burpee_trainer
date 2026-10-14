defmodule BurpeeTrainer.WeekWindow do
  @moduledoc """
  This week's training window as a list: what is done, in order, then what is left. What
  is left is the week's remaining time in 20-minute sessions, each going to the burpee
  type with less time so far, the way `Coach.Policy` picks the next workout. Warmups do
  not count.
  """

  @session_sec 1_200

  @type item ::
          %{
            status: :done,
            burpee_type: atom(),
            completed_at: DateTime.t(),
            duration_sec: non_neg_integer()
          }
          | %{status: :left, burpee_type: atom(), duration_sec: pos_integer()}

  @spec lay_out([map()], non_neg_integer()) :: [item()]
  def lay_out(week_sessions, target_sec) do
    counted =
      week_sessions
      |> Enum.reject(&(Map.get(&1, :tags) == "warmup"))
      |> Enum.filter(&(is_integer(&1.duration_sec_actual) and &1.duration_sec_actual > 0))
      |> Enum.sort_by(& &1.completed_at, DateTime)

    done =
      Enum.map(
        counted,
        &%{
          status: :done,
          burpee_type: &1.burpee_type,
          completed_at: &1.completed_at,
          duration_sec: &1.duration_sec_actual
        }
      )

    totals =
      Enum.reduce(counted, %{six_count: 0, navy_seal: 0}, fn s, acc ->
        Map.update(acc, s.burpee_type, s.duration_sec_actual, &(&1 + s.duration_sec_actual))
      end)

    remaining = max(target_sec - Enum.sum(Map.values(totals)), 0)
    done ++ left(remaining, totals, [])
  end

  defp left(0, _totals, acc), do: Enum.reverse(acc)

  defp left(remaining, totals, acc) do
    type = if totals.six_count <= totals.navy_seal, do: :six_count, else: :navy_seal
    sec = min(@session_sec, remaining)

    left(
      remaining - sec,
      Map.update!(totals, type, &(&1 + sec)),
      [%{status: :left, burpee_type: type, duration_sec: sec} | acc]
    )
  end
end
