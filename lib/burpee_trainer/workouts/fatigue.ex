defmodule BurpeeTrainer.Workouts.Fatigue do
  @moduledoc """
  How a paced session went inside it, from detected rep times against the program.

  Each detection is matched to the scheduled rep it lands nearest, within half that rep's
  interval, so one missed or extra detection never shifts the reps after it. A rep the
  athlete fell a whole interval behind on reads as missed, so slipping shows up as late
  lag, missed reps, or both.

  The camera must have caught most of the opening third, when the athlete is fresh;
  otherwise only `coverage` is returned and late misses could not be told from a camera
  that never worked.
  """

  @min_opening_coverage 0.8
  @slip_lag_sec 1.5
  @slip_miss_fraction 0.3
  @segment_reps 10

  @type event ::
          %{kind: :work, reps: pos_integer(), sec_per_rep: number()}
          | %{kind: :rest, duration_sec: number()}

  @type t :: %{
          coverage: float() | nil,
          pace_delta_sec: float() | nil,
          decline: float() | nil,
          slip_at_sec: float() | nil,
          kept_up: boolean() | nil,
          recovery_delta_sec: float() | nil
        }

  @empty %{
    coverage: nil,
    pace_delta_sec: nil,
    decline: nil,
    slip_at_sec: nil,
    kept_up: nil,
    recovery_delta_sec: nil
  }

  @doc """
  `cadence_ms` are rep completion times in ms from the session start; `events` are the
  program's work and rest events in order (other kinds are ignored).
  """
  @spec compute([non_neg_integer()], [map()]) :: t()
  def compute(cadence_ms, events) when is_list(cadence_ms) and is_list(events) do
    slots = schedule(events)

    if slots == [] do
      @empty
    else
      matched = match(Enum.sort(cadence_ms) |> Enum.map(&(&1 / 1_000)), slots)
      coverage = Enum.count(matched, & &1.t) / length(matched)

      if opening_coverage(matched) < @min_opening_coverage do
        %{@empty | coverage: round3(coverage)}
      else
        slip_at = slip_at(matched)

        %{
          coverage: round3(coverage),
          pace_delta_sec: matched |> work_pairs() |> Enum.map(fn {a, p} -> a - p end) |> median(),
          decline: decline(matched),
          slip_at_sec: slip_at,
          kept_up: is_nil(slip_at),
          recovery_delta_sec: recovery_delta(matched)
        }
      end
    end
  end

  @doc """
  A stored session's fatigue as the coach and Claude read it: nil without camera reps, only
  the camera's coverage when it missed the start.
  """
  @spec summary(map()) :: map() | nil
  def summary(%{fatigue_coverage: nil}), do: nil
  def summary(%{fatigue_coverage: coverage, kept_up: nil}), do: %{"camera_coverage" => coverage}

  def summary(session) do
    %{
      "camera_coverage" => session.fatigue_coverage,
      "kept_up" => session.kept_up,
      "slip_at_sec" => session.slip_at_sec,
      "decline" => session.fatigue_decline,
      "pace_delta_sec" => session.pace_delta_sec,
      "recovery_delta_sec" => session.recovery_delta_sec
    }
  end

  @doc """
  Fatigue for a stored session: its `cadence_ms` JSON and its compiled program snapshot
  (string or atom keys). Every field is nil without detected reps or a program.
  """
  @spec for_session(String.t() | nil, map() | nil) :: t()
  def for_session(cadence_json, program_snapshot)
      when is_binary(cadence_json) and is_map(program_snapshot) do
    with {:ok, [_ | _] = cadence} <- Jason.decode(cadence_json),
         true <- Enum.all?(cadence, &(is_integer(&1) and &1 >= 0)) do
      compute(cadence, snapshot_events(program_snapshot))
    else
      _ -> @empty
    end
  end

  def for_session(_cadence_json, _program_snapshot), do: @empty

  defp snapshot_events(snapshot) do
    for event <- List.wrap(get(snapshot, :events)), is_map(event) do
      case get(event, :kind) do
        kind when kind in ["work", :work] ->
          %{
            kind: :work,
            reps: get(event, :reps),
            sec_per_rep: micros(get(event, :sec_per_rep_us))
          }

        kind when kind in ["rest", :rest] ->
          %{kind: :rest, duration_sec: millis(get(event, :duration_ms))}

        _other ->
          %{kind: :unknown}
      end
    end
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp micros(us) when is_integer(us), do: us / 1_000_000
  defp micros(_us), do: nil
  defp millis(ms) when is_integer(ms), do: ms / 1_000
  defp millis(_ms), do: nil

  # Every scheduled rep: when it is due to finish, its planned interval, and where it sits.
  defp schedule(events) do
    events
    |> Enum.reduce({[], 0.0, 0.0, 0}, fn
      %{kind: :work, reps: reps, sec_per_rep: spr}, {acc, clock, rest, set}
      when is_integer(reps) and reps > 0 and is_number(spr) and spr > 0 ->
        start = clock + rest

        slots =
          for k <- 1..reps do
            %{
              at: start + k * spr,
              interval: spr,
              set: set,
              first?: k == 1,
              rest_before: if(k == 1, do: rest, else: 0.0)
            }
          end

        {acc ++ slots, start + reps * spr, 0.0, set + 1}

      %{kind: :rest, duration_sec: d}, {acc, clock, rest, set} when is_number(d) and d >= 0 ->
        {acc, clock, rest + d, set}

      _other, acc ->
        acc
    end)
    |> elem(0)
  end

  # Both lists are in time order; a detection outside every remaining window is dropped.
  defp match(times, slots), do: match(times, slots, [])

  defp match(_times, [], acc), do: Enum.reverse(acc)

  defp match([], [slot | rest], acc), do: match([], rest, [Map.put(slot, :t, nil) | acc])

  defp match([t | times] = all, [slot | rest] = slots, acc) do
    window = slot.interval / 2

    cond do
      t < slot.at - window -> match(times, slots, acc)
      t > slot.at + window -> match(all, rest, [Map.put(slot, :t, nil) | acc])
      true -> match(times, rest, [Map.put(slot, :t, t) | acc])
    end
  end

  defp opening_coverage(matched) do
    opening = Enum.take(matched, max(1, div(length(matched), 3)))
    Enum.count(opening, & &1.t) / length(opening)
  end

  # Actual vs planned interval between consecutive reps of one set, both detected.
  defp work_pairs(matched) do
    matched
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [%{t: a, set: s}, %{t: b, set: s, interval: i}] when is_number(a) and is_number(b) ->
        [{b - a, i}]

      _other ->
        []
    end)
  end

  defp decline(matched) do
    third = div(length(matched), 3)

    with true <- third > 0,
         first when first != nil <- ratio(Enum.take(matched, third)),
         last when last != nil <- ratio(Enum.take(matched, -third)) do
      round3(last - first)
    else
      _ -> nil
    end
  end

  defp ratio(slots), do: slots |> work_pairs() |> Enum.map(fn {a, p} -> a / p end) |> median()

  # Lag is net of the opening segment, since everyone lands some fixed time after the beep.
  # The slip starts at the first segment from which every later segment slipped too.
  defp slip_at(matched) do
    [opening | _] = segments = segments(matched)
    baseline = median(lags(opening)) || 0.0

    segments
    |> Enum.reverse()
    |> Enum.take_while(&slipped?(&1, baseline))
    |> List.last()
    |> case do
      nil -> nil
      [first | _] -> round3(first.at - first.interval)
    end
  end

  # Each set in even segments of at most @segment_reps, so no short tail segment is left
  # where one miss is a large fraction.
  defp segments(matched) do
    matched
    |> Enum.chunk_by(& &1.set)
    |> Enum.flat_map(fn set ->
      count = ceil(length(set) / @segment_reps)
      size = ceil(length(set) / count)
      Enum.chunk_every(set, size)
    end)
  end

  # One miss is a camera blink, never a slip on its own.
  defp slipped?(segment, baseline) do
    misses = Enum.count(segment, &is_nil(&1.t))
    lag = segment |> lags() |> median()

    (misses >= 2 and misses / length(segment) > @slip_miss_fraction) or
      (is_number(lag) and lag - baseline > @slip_lag_sec)
  end

  defp lags(segment), do: for(%{t: t, at: at} <- segment, is_number(t), do: t - at)

  defp recovery_delta(matched) do
    matched
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [%{t: a}, %{t: b, first?: true, rest_before: r, interval: i}]
      when is_number(a) and is_number(b) and r > 0 ->
        [b - a - (r + i)]

      _other ->
        []
    end)
    |> median()
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    value =
      if rem(n, 2) == 1,
        do: Enum.at(sorted, mid),
        else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2

    round3(value)
  end

  defp round3(nil), do: nil
  defp round3(value), do: Float.round(value / 1, 3)
end
