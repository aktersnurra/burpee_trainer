defmodule BurpeeTrainer.Coach.RestFitter do
  @moduledoc """
  Turns a workout layout into an exact workout definition map.

  Each gap between sets is the tail of the last rep's beat (`sec_per_rep - sec_per_burpee`)
  followed by a rest, and the layout gives every rest as `{"sec": n}`, exactly n seconds, or
  `{"share": w}`, a share by weight of the phase's time left after its sets, tails and exact
  rests. A phase with a gap ends exactly at its anchor (the next timed rest, or the workout's
  length); a phase of one set may miss it by the request's timing tolerance. The fitter never
  changes the set order, repetitions or movement timing.
  """

  alias BurpeeTrainer.Coach.WorkoutRequest

  @us 1_000_000
  @ms 1_000

  @type reason ::
          :invalid_layout
          | :wrong_phase_count
          | :wrong_rest_count
          | :invalid_rest
          | :timing_not_whole_millisecond
          | :active_exceeds_cadence
          | :phase_overfull
          | :pause_shorter_than_tail
          | :phase_misses_anchor
          | :total_not_whole_second

  @spec fit(WorkoutRequest.t(), map()) :: {:ok, map()} | {:error, {reason(), map()}}
  def fit(%WorkoutRequest{} = request, %{"phases" => phases} = layout) when is_list(phases) do
    expected_phases = length(request.timed_rests) + 1

    with :ok <-
           check(length(phases) == expected_phases, :wrong_phase_count, %{
             expected: expected_phases,
             actual: length(phases)
           }),
         {:ok, parsed_phases} <- parse_phases(phases),
         {:ok, events, total_us} <- fit_phases(parsed_phases, request) do
      {:ok,
       %{
         "version" => 1,
         "name" => layout["name"],
         "rationale" => layout["rationale"],
         "burpee_type" => request.burpee_type,
         "pacing_style" => request.pacing_style,
         "target_reps" => request.target_reps,
         "target_duration_sec" => div(total_us, @us),
         "events" => events
       }}
    end
  end

  def fit(%WorkoutRequest{}, _layout), do: {:error, {:invalid_layout, %{}}}

  @doc "Returns what went wrong and what to change, for whoever wrote the layout."
  @spec describe({reason(), map()}) :: String.t()
  def describe({:phase_overfull, %{phase: phase, needed_us: needed, available_us: available} = d}) do
    "phase #{phase} needs #{clock(needed)} but ends at #{anchor(d)}, #{span(available)} after it starts: " <>
      "#{span(d.movement_us)} of sets, #{span(d.tail_us)} of cadence tails and #{span(d.exact_us)} of exact rests. " <>
      "Take #{span(needed - available)} out: fewer reps, a shorter sec_per_rep, shorter exact rests" <>
      if(d.anchor == :timed_rest,
        do: ", or a later timed rest.",
        else: ", or a longer target_duration_sec."
      )
  end

  def describe({:phase_misses_anchor, %{adjustable: true} = d}) do
    "phase #{d.phase}'s sets and exact rests end at #{clock(d.end_us)}, #{span(d.target_us - d.end_us)} before " <>
      "#{anchor(d)}. Add #{span(d.target_us - d.end_us)} to its rests, or make one of them " <>
      ~s({"share": 1} to take up the difference.)
  end

  def describe({:phase_misses_anchor, %{adjustable: false} = d}) do
    difference = d.target_us - d.end_us
    tolerance = WorkoutRequest.timing_tolerance_sec()

    "phase #{d.phase} is one set, so nothing in it can stretch: it ends at #{clock(d.end_us)}, " <>
      "#{span(abs(difference))} #{if difference > 0, do: "before", else: "after"} #{anchor(d)}, " <>
      "and may be at most #{tolerance} s off. " <>
      tail_note(d) <> fix_for_single_set(d)
  end

  def describe({:pause_shorter_than_tail, %{phase: phase, pause_us: pause, tail_us: tail}}),
    do:
      "the timed rest after phase #{phase} is #{seconds(pause)} s, but the last rep's beat before it " <>
        "still has #{seconds(tail)} s to run (sec_per_rep - sec_per_burpee). Make the timed rest " <>
        "longer than #{seconds(tail)} s, or end phase #{phase} with a smaller cadence tail."

  def describe({:wrong_rest_count, %{phase: phase, sets: sets, rests: rests}}),
    do:
      "phase #{phase} has #{sets} sets, so it needs #{sets - 1} rests (one per gap), not #{rests}."

  def describe({:invalid_rest, %{phase: phase, gap: gap}}),
    do: ~s(phase #{phase} rest #{gap} must be {"sec": n} with n >= 0, or {"share": w} with w > 0.)

  def describe({:timing_not_whole_millisecond, %{phase: phase, value: value}}),
    do:
      "phase #{phase} has #{inspect(value)} s; times are whole milliseconds (at most three decimals)."

  def describe({:active_exceeds_cadence, %{phase: phase}}),
    do: "phase #{phase} has a set whose sec_per_burpee is longer than its sec_per_rep."

  def describe({:wrong_phase_count, %{expected: expected, actual: actual}}),
    do:
      "the layout has #{actual} phases; with #{expected - 1} timed rests it needs #{expected} (one more than the timed rests)."

  def describe({:total_not_whole_second, %{total_us: total}}),
    do:
      "the workout comes to #{seconds(total)} s; it must be whole seconds. Change a rest or the last set's timing by " <>
        "#{seconds(rem(total, @us))} s."

  def describe({reason, details}), do: "#{reason} #{inspect(details)}"

  defp anchor(%{anchor: :timed_rest, target_us: target}), do: "the timed rest at #{clock(target)}"
  defp anchor(%{target_us: target}), do: "target_duration_sec (#{clock(target)})"

  # A workout ends when its last rep's movement ends; the rest of that beat is not counted.
  defp tail_note(%{anchor: :end, last_tail_us: tail, end_us: ending, target_us: target})
       when tail > 0 and ending < target,
       do:
         "The workout ends when the last rep's movement ends: the #{span(tail)} after the last rep is not part of the workout. "

  defp tail_note(_details), do: ""

  defp fix_for_single_set(%{anchor: :end, end_us: ending}) when rem(ending, @us) == 0,
    do: "Set target_duration_sec #{div(ending, @us)}, or change its reps or sec_per_rep."

  defp fix_for_single_set(%{anchor: :timed_rest}),
    do: "Move the timed rest, or change the set's reps or sec_per_rep."

  defp fix_for_single_set(_details), do: "Change the set's reps or sec_per_rep."

  defp parse_phases(phases) do
    phases
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {phase, index}, {:ok, parsed} ->
      case parse_phase(phase, index) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp parse_phase(%{"sets" => [_ | _] = sets, "rests" => rests}, index) when is_list(rests) do
    with :ok <-
           check(length(rests) == length(sets) - 1, :wrong_rest_count, %{
             phase: index,
             sets: length(sets),
             rests: length(rests)
           }),
         {:ok, parsed_rests} <- parse_rests(rests, index),
         {:ok, parsed_sets} <- parse_sets(sets, index) do
      {:ok, %{index: index, sets: parsed_sets, rests: parsed_rests}}
    end
  end

  defp parse_phase(_phase, index), do: {:error, {:invalid_layout, %{phase: index}}}

  # Exact rests become {:sec, microseconds}; shares stay weights until the phase is fitted.
  defp parse_rests(rests, phase) do
    rests
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {rest, gap}, {:ok, parsed} ->
      case parse_rest(rest, phase, gap) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp parse_rest(%{"sec" => seconds} = rest, phase, _gap)
       when map_size(rest) == 1 and is_number(seconds) and seconds >= 0 do
    case whole_milliseconds(seconds, phase) do
      {:ok, microseconds} -> {:ok, {:sec, microseconds}}
      error -> error
    end
  end

  defp parse_rest(%{"share" => weight} = rest, phase, gap) when map_size(rest) == 1 do
    case decimal_ratio(weight) do
      {:ok, ratio} -> {:ok, {:share, ratio}}
      :error -> {:error, {:invalid_rest, %{phase: phase, gap: gap}}}
    end
  end

  defp parse_rest(_rest, phase, gap), do: {:error, {:invalid_rest, %{phase: phase, gap: gap}}}

  defp parse_sets(sets, phase) do
    sets
    |> Enum.reduce_while({:ok, []}, fn
      %{"reps" => reps, "sec_per_rep" => cadence, "sec_per_burpee" => active} = raw, {:ok, parsed}
      when is_integer(reps) and reps > 0 and is_number(cadence) and cadence > 0 and
             is_number(active) and active > 0 ->
        with {:ok, cadence_us} <- whole_milliseconds(cadence, phase),
             {:ok, active_us} <- whole_milliseconds(active, phase),
             :ok <- check(active_us <= cadence_us, :active_exceeds_cadence, %{phase: phase}) do
          set = %{
            raw: raw,
            movement_us: (reps - 1) * cadence_us + active_us,
            tail_us: cadence_us - active_us
          }

          {:cont, {:ok, [set | parsed]}}
        else
          error -> {:halt, error}
        end

      _invalid, _parsed ->
        {:halt, {:error, {:invalid_layout, %{phase: phase}}}}
    end)
    |> reverse_ok()
  end

  # Integer seconds are already exact, so never route them through floating tolerance math.
  defp whole_milliseconds(seconds, _phase) when is_integer(seconds), do: {:ok, seconds * @us}

  defp whole_milliseconds(seconds, phase) when is_float(seconds) do
    with true <- finite_number?(seconds),
         {:ok, {coefficient, decimal_scale}} <- decimal_ratio(seconds),
         {:ok, milliseconds} <- decimal_milliseconds(coefficient, decimal_scale) do
      {:ok, milliseconds * @ms}
    else
      _ -> {:error, {:timing_not_whole_millisecond, %{phase: phase, value: seconds}}}
    end
  end

  # Float input is read through its shortest round-trippable decimal form. This avoids an
  # overflowing float multiplication while preserving the JSON decimal value's millisecond grid.
  defp decimal_milliseconds(coefficient, decimal_scale) when decimal_scale <= 3,
    do: {:ok, coefficient * Integer.pow(10, 3 - decimal_scale)}

  defp decimal_milliseconds(coefficient, decimal_scale) do
    divisor = Integer.pow(10, decimal_scale - 3)

    if rem(coefficient, divisor) == 0,
      do: {:ok, div(coefficient, divisor)},
      else: :error
  end

  defp fit_phases(phases, request) do
    anchors = Enum.map(request.timed_rests, &{&1.start_sec * @us, &1.duration_sec * @us})
    target_us = request.target_duration_sec * @us
    tolerance_us = WorkoutRequest.timing_tolerance_sec() * @us
    last_phase = length(phases)

    phases
    |> Enum.reduce_while({:ok, [], 0}, fn phase, {:ok, events, cursor} ->
      {phase_target, anchor} =
        if phase.index < last_phase,
          do: {elem(Enum.at(anchors, phase.index - 1), 0), :timed_rest},
          else: {target_us, :end}

      target = %{target_us: phase_target, anchor: anchor}

      with {:ok, phase_events, phase_end} <- fit_phase(phase, cursor, target, tolerance_us),
           {:ok, fixed_events, next_cursor} <- fixed_pause(phase, anchors, phase_end, last_phase) do
        {:cont, {:ok, events ++ phase_events ++ fixed_events, next_cursor}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events, total_us} when rem(total_us, @us) == 0 -> {:ok, events, total_us}
      {:ok, _events, total_us} -> {:error, {:total_not_whole_second, %{total_us: total_us}}}
      error -> error
    end
  end

  defp fit_phase(%{sets: [set], rests: []} = phase, cursor, target, tolerance_us) do
    phase_end = cursor + set.movement_us

    if abs(phase_end - target.target_us) <= tolerance_us do
      {:ok, [work(set)], phase_end}
    else
      {:error,
       {:phase_misses_anchor,
        Map.merge(target, %{
          phase: phase.index,
          end_us: phase_end,
          adjustable: false,
          last_tail_us: set.tail_us
        })}}
    end
  end

  defp fit_phase(%{sets: sets, rests: rests} = phase, cursor, target, _tolerance_us) do
    movement_us = Enum.sum(Enum.map(sets, & &1.movement_us))
    tail_us = sets |> Enum.drop(-1) |> Enum.map(& &1.tail_us) |> Enum.sum()
    exact_us = Enum.sum(for {:sec, microseconds} <- rests, do: microseconds)
    needed_us = movement_us + tail_us + exact_us
    available_us = target.target_us - cursor
    spare_us = available_us - needed_us
    shares = for {:share, ratio} <- rests, do: ratio

    parts =
      Map.merge(target, %{
        phase: phase.index,
        movement_us: movement_us,
        tail_us: tail_us,
        exact_us: exact_us
      })

    cond do
      spare_us < 0 ->
        {:error,
         {:phase_overfull, Map.merge(parts, %{needed_us: needed_us, available_us: available_us})}}

      shares == [] and spare_us > 0 ->
        {:error,
         {:phase_misses_anchor,
          Map.merge(parts, %{end_us: target.target_us - spare_us, adjustable: true})}}

      true ->
        rests_us = rest_durations(rests, spare_us, shares)
        {:ok, phase_events(sets, rests_us), target.target_us}
    end
  end

  # Exact rests keep their length; the spare time is shared by weight, in whole milliseconds.
  defp rest_durations(rests, _spare_us, []), do: Enum.map(rests, fn {:sec, us} -> us end)

  defp rest_durations(rests, spare_us, shares) do
    shared =
      spare_us |> div(@ms) |> distribute(normalize_weights(shares)) |> Enum.map(&(&1 * @ms))

    {durations, []} =
      Enum.map_reduce(rests, shared, fn
        {:sec, us}, remaining -> {us, remaining}
        {:share, _ratio}, [us | remaining] -> {us, remaining}
      end)

    durations
  end

  # A rest of zero leaves the next set on the next beat: no rest event between them.
  defp phase_events(sets, rests_us) do
    sets
    |> Enum.zip(rests_us ++ [0])
    |> Enum.flat_map(fn
      {set, 0} -> [work(set)]
      {set, rest_us} -> [work(set), rest(rest_us)]
    end)
  end

  defp fixed_pause(%{index: index}, _anchors, phase_end, last_phase) when index == last_phase,
    do: {:ok, [], phase_end}

  defp fixed_pause(%{index: index, sets: sets}, anchors, phase_end, _last_phase) do
    {_start_us, duration_us} = Enum.at(anchors, index - 1)
    tail_us = List.last(sets).tail_us
    rest_us = duration_us - tail_us

    if rest_us >= @ms do
      {:ok, [rest(rest_us)], phase_end + duration_us}
    else
      {:error,
       {:pause_shorter_than_tail, %{phase: index, pause_us: duration_us, tail_us: tail_us}}}
    end
  end

  # Distributes a whole-millisecond budget proportionally; rounding remainder belongs to the last
  # share. Weights are positive normalized integers, so this is exact even for extreme input.
  defp distribute(total_ms, weights) do
    total_weight = Enum.sum(weights)
    floors = Enum.map(weights, &div(total_ms * &1, total_weight))
    List.update_at(floors, -1, &(&1 + total_ms - Enum.sum(floors)))
  end

  # Shares are positive decimals; scaled to integers with no common factor, they divide exactly.
  defp normalize_weights(ratios) do
    scale = ratios |> Enum.map(&elem(&1, 1)) |> Enum.max()

    normalized =
      Enum.map(ratios, fn {coefficient, decimal_scale} ->
        coefficient * Integer.pow(10, scale - decimal_scale)
      end)

    divisor = Enum.reduce(normalized, &Integer.gcd/2)
    Enum.map(normalized, &div(&1, divisor))
  end

  defp decimal_ratio(weight) when is_integer(weight) and weight > 0, do: {:ok, {weight, 0}}

  defp decimal_ratio(weight) when is_float(weight) and weight > 0 do
    case Regex.run(
           ~r/^([0-9]+)(?:\.([0-9]+))?(?:e([+-]?\d+))?$/i,
           :erlang.float_to_binary(weight, [:short])
         ) do
      [_, whole, fractional, exponent] ->
        decimal_ratio_parts(whole, fractional, exponent)

      [_, whole, fractional] ->
        decimal_ratio_parts(whole, fractional, "0")

      [_, whole] ->
        decimal_ratio_parts(whole, "", "0")

      nil ->
        :error
    end
  end

  defp decimal_ratio(_weight), do: :error

  defp decimal_ratio_parts(whole, fractional, exponent) do
    coefficient = String.to_integer(whole <> fractional)
    scale = String.length(fractional) - String.to_integer(exponent)

    if scale >= 0 do
      {:ok, {coefficient, scale}}
    else
      {:ok, {coefficient * Integer.pow(10, -scale), 0}}
    end
  end

  defp finite_number?(value) when is_float(value) do
    case :erlang.float_to_binary(value, [:short]) do
      "inf" -> false
      "-inf" -> false
      "nan" -> false
      _ -> value == value
    end
  end

  defp work(set),
    do: Map.put(Map.take(set.raw, ~w[reps sec_per_rep sec_per_burpee]), "kind", "work")

  defp rest(microseconds), do: %{"kind" => "rest", "duration_sec" => microseconds / @us}
  defp check(true, _reason, _details), do: :ok
  defp check(false, reason, details), do: {:error, {reason, details}}
  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp seconds(microseconds) do
    if rem(microseconds, @us) == 0,
      do: Integer.to_string(div(microseconds, @us)),
      else: :erlang.float_to_binary(microseconds / @us, [:short])
  end

  # Under a minute as "8 s", otherwise as a clock: "1:28".
  defp span(microseconds) when microseconds < 60 * @us, do: "#{seconds(microseconds)} s"
  defp span(microseconds), do: clock(microseconds)

  defp clock(microseconds) do
    seconds = div(microseconds, @us)
    "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
  end
end
