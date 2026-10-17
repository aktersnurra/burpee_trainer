defmodule BurpeeTrainer.Coach.RestFitter do
  @moduledoc """
  Turns an LLM workout layout into an exact workout definition map.

  The fitter only distributes ordinary rest time. It never changes the submitted set order,
  repetitions, or movement timing.
  """

  alias BurpeeTrainer.Coach.WorkoutRequest

  @us 1_000_000
  @ms 1_000

  @type reason ::
          :invalid_layout
          | :wrong_phase_count
          | :wrong_weight_count
          | :non_positive_weight
          | :timing_not_whole_millisecond
          | :active_exceeds_cadence
          | :phase_overfull
          | :rest_shorter_than_tail
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

  @doc "Returns a one-line explanation suitable for a layout correction prompt."
  @spec describe({reason(), map()}) :: String.t()
  def describe(
        {:phase_overfull, %{phase: phase, movement_us: movement, available_us: available}}
      ),
      do:
        "phase #{phase} needs #{clock(movement)} of movement but only #{clock(available)} is available"

  def describe(
        {:rest_shorter_than_tail, %{phase: phase, gap: gap, pause_us: pause, tail_us: tail}}
      ),
      do:
        "phase #{phase} pause #{gap} would be #{seconds(pause)} s, shorter than its #{seconds(tail)} s cadence tail"

  def describe({:pause_shorter_than_tail, %{phase: phase, pause_us: pause, tail_us: tail}}),
    do:
      "the fixed pause after phase #{phase} (#{seconds(pause)} s) is shorter than its #{seconds(tail)} s cadence tail"

  def describe({:phase_misses_anchor, %{phase: phase, end_us: ending, target_us: target}}),
    do:
      "phase #{phase} has no pauses to adjust and ends at #{clock(ending)} instead of #{clock(target)} (±10 s)"

  def describe({reason, details}), do: "#{reason} #{inspect(details)}"

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

  defp parse_phase(%{"sets" => [_ | _] = sets, "rest_weights" => weights}, index)
       when is_list(weights) do
    with :ok <-
           check(length(weights) == length(sets) - 1, :wrong_weight_count, %{
             phase: index,
             sets: length(sets),
             weights: length(weights)
           }),
         {:ok, normalized_weights} <- normalize_weights(weights, index),
         {:ok, parsed_sets} <- parse_sets(sets, index) do
      {:ok, %{index: index, sets: parsed_sets, weights: normalized_weights}}
    end
  end

  defp parse_phase(_phase, index), do: {:error, {:invalid_layout, %{phase: index}}}

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
      phase_target =
        if phase.index < last_phase,
          do: elem(Enum.at(anchors, phase.index - 1), 0),
          else: target_us

      with {:ok, phase_events, phase_end} <- fit_phase(phase, cursor, phase_target, tolerance_us),
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

  defp fit_phase(%{sets: [set], weights: []} = phase, cursor, target_end, tolerance_us) do
    phase_end = cursor + set.movement_us

    if abs(phase_end - target_end) <= tolerance_us do
      {:ok, [work(set)], phase_end}
    else
      {:error,
       {:phase_misses_anchor, %{phase: phase.index, end_us: phase_end, target_us: target_end}}}
    end
  end

  defp fit_phase(%{sets: sets, weights: weights} = phase, cursor, target_end, _tolerance_us) do
    movement_us = Enum.sum(Enum.map(sets, & &1.movement_us))
    available_us = target_end - cursor
    budget_us = available_us - movement_us

    if budget_us <= 0 do
      {:error,
       {:phase_overfull,
        %{phase: phase.index, movement_us: movement_us, available_us: available_us}}}
    else
      pauses_us = budget_us |> div(@ms) |> distribute(weights) |> Enum.map(&(&1 * @ms))

      phase_events(sets, pauses_us, phase.index)
      |> case do
        {:ok, events} -> {:ok, events, target_end}
        error -> error
      end
    end
  end

  defp phase_events(sets, pauses, phase) do
    sets
    |> Enum.zip(pauses ++ [nil])
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn
      {{set, nil}, _gap}, {:ok, events} ->
        {:cont, {:ok, events ++ [work(set)]}}

      {{set, pause_us}, gap}, {:ok, events} ->
        rest_us = pause_us - set.tail_us

        if rest_us >= @ms do
          {:cont, {:ok, events ++ [work(set), rest(rest_us)]}}
        else
          {:halt,
           {:error,
            {:rest_shorter_than_tail,
             %{phase: phase, gap: gap, pause_us: pause_us, tail_us: set.tail_us}}}}
        end
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

  # Distributes a whole-millisecond budget proportionally; rounding remainder belongs to last gap.
  # Weights are positive normalized integers, so this is exact even for decimal or extreme input.
  defp distribute(total_ms, weights) do
    total_weight = Enum.sum(weights)
    floors = Enum.map(weights, &div(total_ms * &1, total_weight))
    List.update_at(floors, -1, &(&1 + total_ms - Enum.sum(floors)))
  end

  defp normalize_weights([], _phase), do: {:ok, []}

  defp normalize_weights(weights, phase) do
    with {:ok, ratios} <- parse_weight_ratios(weights, phase) do
      scale = ratios |> Enum.map(&elem(&1, 1)) |> Enum.max()

      normalized =
        Enum.map(ratios, fn {coefficient, decimal_scale} ->
          coefficient * Integer.pow(10, scale - decimal_scale)
        end)

      divisor = Enum.reduce(normalized, &Integer.gcd/2)
      {:ok, Enum.map(normalized, &div(&1, divisor))}
    end
  end

  defp parse_weight_ratios(weights, phase) do
    weights
    |> Enum.reduce_while({:ok, []}, fn weight, {:ok, ratios} ->
      case decimal_ratio(weight) do
        {:ok, ratio} -> {:cont, {:ok, [ratio | ratios]}}
        :error -> {:halt, {:error, {:non_positive_weight, %{phase: phase}}}}
      end
    end)
    |> reverse_ok()
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
  defp seconds(microseconds), do: :erlang.float_to_binary(microseconds / @us, decimals: 3)

  defp clock(microseconds) do
    seconds = div(microseconds, @us)
    "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
  end
end
