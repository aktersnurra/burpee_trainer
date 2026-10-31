defmodule BurpeeTrainer.Workouts.Shape do
  @moduledoc """
  Pure: a workout's shape in one line, for an athlete who reads it at a glance: its sets,
  how often a rep starts, and the rest between sets, such as `5 × 3 · every 8s · 4:30 rest`.
  A value that varies reads as its range. Rest is the whole pause between two sets: the
  tail of the last rep's beat and any rest after it, as the table shows it.
  """

  @spec describe(map()) :: String.t() | nil
  def describe(%{"events" => events}) when is_list(events) do
    sets = sets(events)

    case sets do
      [] ->
        nil

      sets ->
        [count(sets), every(sets), rest(sets)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")
    end
  end

  def describe(_definition), do: nil

  # Each set with the pause that follows it, until the next set; the last has none.
  defp sets(events) do
    {sets, _} =
      events
      |> Enum.drop_while(&(&1["kind"] != "work"))
      |> Enum.reduce({[], nil}, fn
        %{"kind" => "work"} = work, {sets, _} ->
          {[%{work: work, rest_ms: tail_ms(work), last?: true} | mark_not_last(sets)], work}

        %{"kind" => "rest", "duration_sec" => seconds}, {[set | sets], work} ->
          {[%{set | rest_ms: set.rest_ms + round(seconds * 1_000)} | sets], work}

        _other, acc ->
          acc
      end)

    sets = Enum.reverse(sets)
    trailing? = List.last(events)["kind"] == "rest"
    Enum.map(sets, &if(&1.last? and not trailing?, do: %{&1 | rest_ms: 0}, else: &1))
  end

  defp mark_not_last([set | rest]), do: [%{set | last?: false} | rest]
  defp mark_not_last([]), do: []

  defp tail_ms(work),
    do: round((work["sec_per_rep"] - work["sec_per_burpee"]) * 1_000)

  defp count([set]), do: "1 set of #{set.work["reps"]}"

  defp count(sets) do
    case sets |> Enum.map(& &1.work["reps"]) |> Enum.uniq() do
      [reps] -> "#{length(sets)} × #{reps}"
      reps -> "#{length(sets)} sets of #{Enum.min(reps)}–#{Enum.max(reps)}"
    end
  end

  defp every(sets) do
    case sets |> Enum.map(&round(&1.work["sec_per_rep"] * 1_000)) |> Enum.uniq() do
      [cadence] -> "every #{seconds(cadence)}s"
      cadences -> "every #{seconds(Enum.min(cadences))}–#{seconds(Enum.max(cadences))}s"
    end
  end

  # The rests between sets; the last set's pause is the end, not a rest.
  defp rest(sets) do
    case sets |> Enum.drop(-1) |> Enum.map(&round(&1.rest_ms / 1_000)) |> Enum.uniq() do
      [] -> nil
      [0] -> "no rest"
      rests -> range(rests, &clock/1) <> " rest"
    end
  end

  defp range([value], format), do: format.(value)
  defp range(values, format), do: format.(Enum.min(values)) <> "–" <> format.(Enum.max(values))

  defp seconds(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}"
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1_000, [:short])

  @doc "Seconds as the athlete reads a rest: `45s` under a minute, else `4:30`."
  @spec clock(non_neg_integer()) :: String.t()
  def clock(seconds) when seconds < 60, do: "#{seconds}s"

  def clock(seconds),
    do: "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
end
