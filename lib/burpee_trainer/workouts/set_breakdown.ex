defmodule BurpeeTrainer.Workouts.SetBreakdown do
  @moduledoc """
  A camera session set by set: each set's planned window, the reps the camera counted in
  it and when, and how much of the window was left after the last rep (its slack).

  A set's window runs from its beep (`start_sec`) to the next set's beep: its work and the
  rest after it. The last set's window ends with its work, plus any rest after it. A rep
  belongs to the window it was counted in, so a rep finished in the rest after a set is
  that set's, and one finished after the next beep is the next set's. Reps counted before
  the first set's beep are dropped.

  Times are seconds from the session's start, the same clock as `slip_at_sec`.
  """

  alias BurpeeTrainer.Workouts.Fatigue

  @type t :: %{sets: [map()], active_pace_sec: float() | nil, window_slack: map() | nil}

  @empty %{sets: [], active_pace_sec: nil, window_slack: nil}

  @doc "A stored session's breakdown, from its `cadence_ms` JSON and program snapshot."
  @spec for_session(String.t() | nil, map() | nil) :: t()
  def for_session(cadence_json, program_snapshot) do
    case Fatigue.decode(cadence_json, program_snapshot) do
      {:ok, cadence, events} -> compute(cadence, events)
      :error -> @empty
    end
  end

  @doc """
  `cadence_ms` are rep completion times in ms from the session start; `events` are the
  program's work and rest events in order, as `Workouts.Fatigue.compute/2` takes them.
  """
  @spec compute([non_neg_integer()], [map()]) :: t()
  def compute(cadence_ms, events) when is_list(cadence_ms) and is_list(events) do
    case windows(events) do
      [] ->
        @empty

      windows ->
        times = cadence_ms |> Enum.sort() |> Enum.map(&(&1 / 1_000))
        sets = windows |> assign(times) |> Enum.with_index(1) |> Enum.map(&set/1)

        %{sets: sets, active_pace_sec: active_pace(sets), window_slack: window_slack(sets)}
    end
  end

  # Each set's beep, planned end of work, and the rest that follows it.
  defp windows(events) do
    events
    |> Enum.reduce({[], 0.0, 0.0}, fn
      %{kind: :work, reps: reps, sec_per_rep: spr}, {acc, clock, rest}
      when is_integer(reps) and reps > 0 and is_number(spr) and spr > 0 ->
        start = clock + rest
        work_end = start + reps * spr
        window = %{start: start, work_end: work_end, reps: reps, spr: spr, rest_after: 0.0}
        {[window | acc], work_end, 0.0}

      %{kind: :rest, duration_sec: d}, {[last | acc], clock, rest}
      when is_number(d) and d >= 0 ->
        {[%{last | rest_after: last.rest_after + d} | acc], clock, rest + d}

      %{kind: :rest, duration_sec: d}, {[], clock, rest} when is_number(d) and d >= 0 ->
        {[], clock, rest + d}

      _other, acc ->
        acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp assign(windows, times) do
    last_index = length(windows) - 1

    windows
    |> Enum.with_index()
    |> Enum.map(fn {window, index} ->
      window_end = window.work_end + window.rest_after

      reps =
        Enum.filter(times, fn t ->
          t >= window.start and (index == last_index or t < window_end)
        end)

      Map.merge(window, %{window_end: window_end, times: reps})
    end)
  end

  defp set({window, number}) do
    counted = length(window.times)
    complete? = counted >= window.reps
    last = List.last(window.times)

    %{
      "set" => number,
      "reps_planned" => window.reps,
      "reps" => counted,
      "sec_per_rep_planned" => round2(window.spr),
      "start_sec" => round2(window.start),
      "work_end_sec" => round2(window.work_end),
      "window_end_sec" => round2(window.window_end),
      "window_sec" => round2(window.window_end - window.start),
      "rest_after_sec" => round2(window.rest_after),
      "finish_sec" => if(complete?, do: round2(last - window.start)),
      "finish_vs_plan_sec" => if(complete?, do: round2(last - window.work_end)),
      "slack_sec" => if(complete?, do: round2(window.window_end - last)),
      "active_pace_sec" => if(complete?, do: round2((last - window.start) / counted)),
      "rep_times_sec" => Enum.map(window.times, &round2(&1 - window.start))
    }
  end

  # Seconds from each complete set's beep to its last rep, per rep, over those sets.
  defp active_pace(sets) do
    case Enum.filter(sets, & &1["finish_sec"]) do
      [] ->
        nil

      complete ->
        seconds = complete |> Enum.map(& &1["finish_sec"]) |> Enum.sum()
        reps = complete |> Enum.map(& &1["reps"]) |> Enum.sum()
        round2(seconds / reps)
    end
  end

  # Only complete sets with a rest after them: a window without a rest is all work, so its
  # slack is not comparable with the others'.
  defp window_slack(sets) do
    case Enum.filter(sets, &(&1["slack_sec"] && &1["rest_after_sec"] > 0)) do
      [_, _ | _] = measured ->
        slack = Enum.map(measured, & &1["slack_sec"])

        %{
          "sets_measured" => length(measured),
          "first_sec" => hd(slack),
          "last_sec" => List.last(slack),
          "min_sec" => Enum.min(slack),
          "median_sec" => median(slack),
          "trend_sec_per_set" => slope(Enum.map(measured, &{&1["set"], &1["slack_sec"]}))
        }

      _too_few ->
        nil
    end
  end

  # Least-squares slope of slack on set number.
  defp slope(points) do
    n = length(points)
    mean_x = (points |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / n
    mean_y = (points |> Enum.map(&elem(&1, 1)) |> Enum.sum()) / n
    sxx = points |> Enum.map(fn {x, _} -> (x - mean_x) ** 2 end) |> Enum.sum()
    sxy = points |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end) |> Enum.sum()
    round2(sxy / sxx)
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: round2((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2)
  end

  defp round2(value), do: Float.round(value / 1, 2)
end
