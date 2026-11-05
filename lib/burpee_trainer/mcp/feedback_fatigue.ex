defmodule BurpeeTrainer.Mcp.FeedbackFatigue do
  @moduledoc """
  How the camera saw sessions the athlete gave the same feedback: for each limiter, mood,
  and energy or heat flag, how often they kept up, and the median slack curve and decline.
  Only camera sessions whose opening the camera caught count. A group is a description of
  the selected sessions, not a cause.
  """

  alias BurpeeTrainer.Stats.Median
  alias BurpeeTrainer.Workouts.SetBreakdown

  @doc "Groups with at least one session, and `all` for every camera session selected."
  @spec summarize([map()]) :: map() | nil
  def summarize(sessions) do
    measured =
      for s <- sessions, s.capture_mode == :tracked, is_boolean(s.kept_up) do
        {s, SetBreakdown.for_session(s.cadence_ms, s.program_snapshot).window_slack}
      end

    if measured != [] do
      groups =
        measured
        |> Enum.flat_map(fn {s, _} = row -> Enum.map(keys(s), &{&1, row}) end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {key, rows} -> {key, stats(rows)} end)

      Map.put(groups, "all", stats(measured))
    end
  end

  defp keys(s) do
    [
      s.primary_limiter && "limiter.#{s.primary_limiter}",
      is_integer(s.mood) && "mood.#{s.mood}",
      s.context_low_energy && "low_energy",
      s.context_high_energy && "high_energy",
      s.context_heat_affected && "heat_affected"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp stats(rows) do
    slack = for {_, %{} = w} <- rows, do: w

    %{
      "sessions" => length(rows),
      "kept_up_share" =>
        Float.round(Enum.count(rows, fn {s, _} -> s.kept_up end) / length(rows), 2),
      "median_decline" =>
        median(for {s, _} <- rows, is_number(s.fatigue_decline), do: s.fatigue_decline),
      "slack_sessions" => length(slack),
      "median_slack_trend_sec_per_set" => median(Enum.map(slack, & &1["trend_sec_per_set"])),
      "median_slack_last_share_of_rest" =>
        median(for w <- slack, w["rest_sec"] > 0, do: w["last_sec"] / w["rest_sec"])
    }
  end

  defp median(values) do
    case Median.of(values) do
      nil -> nil
      value -> Float.round(value, 3)
    end
  end
end
