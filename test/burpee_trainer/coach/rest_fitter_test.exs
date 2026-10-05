defmodule BurpeeTrainer.Coach.RestFitterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Coach.{RestFitter, WorkoutRequest}
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition

  defp request(attrs) do
    {:ok, request} =
      WorkoutRequest.new(
        Map.merge(
          %{
            "burpee_type" => "six_count",
            "target_reps" => 20,
            "target_duration_sec" => 120,
            "pacing_style" => "even",
            "recovery" => "required",
            "timed_rests" => [],
            "requested_pace_sec" => nil
          },
          attrs
        )
      )

    request
  end

  defp set(reps, cadence, active),
    do: %{"reps" => reps, "sec_per_rep" => cadence, "sec_per_burpee" => active}

  test "even weights split ordinary pauses equally and hit the total exactly" do
    layout = layout([[set(10, 5.0, 5.0), set(10, 5.0, 5.0)]], [[1]])

    assert {:ok, attrs} = RestFitter.fit(request(%{}), layout)

    assert [
             %{"kind" => "work", "reps" => 10},
             %{"kind" => "rest", "duration_sec" => 20.0},
             %{"kind" => "work", "reps" => 10}
           ] = attrs["events"]

    assert_valid_and_compiled(attrs)
  end

  test "cadence tails are included in pauses, not rest events" do
    layout = layout([[set(10, 6.0, 5.0), set(10, 6.0, 5.0)]], [[1]])

    assert {:ok, %{"events" => [_, %{"kind" => "rest", "duration_sec" => 1.0}, _]}} =
             RestFitter.fit(request(%{}), layout)
  end

  test "reports an overfull phase with microsecond movement and available budgets" do
    layout = layout([[set(15, 5.0, 5.0), set(15, 5.0, 5.0)]], [[1]])

    assert {:error,
            {:phase_overfull, %{phase: 1, movement_us: 150_000_000, available_us: 120_000_000}}} =
             RestFitter.fit(request(%{"target_reps" => 30}), layout)
  end

  test "fits the owner's 140-rep workout with exact fixed pause anchors" do
    request =
      request(%{
        "target_reps" => 140,
        "target_duration_sec" => 1200,
        "requested_pace_sec" => 5.0,
        "pacing_style" => "unbroken",
        "timed_rests" => [
          %{"start_sec" => 660, "duration_sec" => 60},
          %{"start_sec" => 1080, "duration_sec" => 40}
        ]
      })

    eight = set(8, 5.0, 5.0)
    six = set(6, 5.0, 5.0)

    layout =
      layout(
        [List.duplicate(eight, 10), List.duplicate(eight, 6), [six, six]],
        [List.duplicate(1, 9), List.duplicate(1, 5), [1]]
      )

    assert {:ok, attrs} = RestFitter.fit(request, layout)
    definition = assert_valid_and_compiled(attrs)
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    pauses = WorkoutRequest.rest_timeline(definition.events)
    assert {660_000_000, 60_000_000} in pauses
    assert {1_080_000_000, 40_000_000} in pauses
  end

  test "a gapless phase may miss its anchor by at most ten seconds" do
    request =
      request(%{
        "target_reps" => 20,
        "target_duration_sec" => 200,
        "timed_rests" => [%{"start_sec" => 100, "duration_sec" => 20}]
      })

    layout = layout([[set(10, 9.0, 9.0)], [set(5, 8.0, 8.0), set(5, 8.0, 8.0)]], [[], [1]])
    assert {:ok, _} = RestFitter.fit(request, layout)

    too_early = put_in(layout, ["phases", Access.at(0), "sets"], [set(10, 8.0, 8.0)])
    assert {:error, {:phase_misses_anchor, %{phase: 1}}} = RestFitter.fit(request, too_early)
  end

  test "reports cadence-tail boundary errors" do
    short_ordinary_pause = layout([[set(10, 6.0, 5.0), set(10, 6.0, 5.0)]], [[1]])

    assert {:error, {:rest_shorter_than_tail, %{phase: 1, gap: 1, tail_us: 1_000_000}}} =
             RestFitter.fit(request(%{"target_duration_sec" => 119}), short_ordinary_pause)

    fixed_pause_shorter_than_tail =
      layout([[set(10, 7.0, 5.0)], [set(5, 8.0, 8.0), set(5, 8.0, 8.0)]], [[], [1]])

    fixed_request =
      request(%{
        "target_reps" => 20,
        "target_duration_sec" => 200,
        "timed_rests" => [%{"start_sec" => 70, "duration_sec" => 1}]
      })

    assert {:error, {:pause_shorter_than_tail, %{phase: 1, tail_us: 2_000_000}}} =
             RestFitter.fit(fixed_request, fixed_pause_shorter_than_tail)
  end

  test "rejects timing just off the whole-millisecond grid without quantizing it" do
    for cadence <- [5.0000004, 4.9999996] do
      layout = layout([[set(10, cadence, 5.0), set(10, 5.0, 5.0)]], [[1]])

      assert {:error, {:timing_not_whole_millisecond, %{phase: 1, value: ^cadence}}} =
               RestFitter.fit(request(%{}), layout)
    end
  end

  test "returns phase_overfull for huge whole-grid integer and float cadence values" do
    for cadence <- [Integer.pow(10, 306), 1.0e308] do
      layout = layout([[set(10, cadence, 5), set(10, 5, 5)]], [[1]])
      assert {:error, {:phase_overfull, %{phase: 1}}} = RestFitter.fit(request(%{}), layout)
    end
  end

  test "allocates decimal-equivalent and extreme weights without float drift or overflow" do
    sets = List.duplicate(set(10, 5.0, 5.0), 4)
    integer_weights = layout([sets], [[1, 3, 2]])
    decimal_weights = layout([sets], [[0.1, 0.3, 0.2]])

    request = request(%{"target_reps" => 40, "target_duration_sec" => 280})
    assert {:ok, integer_attrs} = RestFitter.fit(request, integer_weights)
    assert {:ok, decimal_attrs} = RestFitter.fit(request, decimal_weights)
    assert ordinary_pause_ms(integer_attrs["events"], 3) == [13_333, 40_000, 26_667]
    assert ordinary_pause_ms(decimal_attrs["events"], 3) == [13_333, 40_000, 26_667]

    two_sets = layout([[set(10, 5.0, 5.0), set(10, 5.0, 5.0)]], [[1.0e308]])
    assert {:ok, attrs} = RestFitter.fit(request(%{}), two_sets)
    assert ordinary_pause_ms(attrs["events"], 1) == [20_000]
  end

  test "puts all multi-millisecond rounding remainder on the final ordinary pause" do
    sets = [set(10, 5.0, 4.998) | List.duplicate(set(10, 5.0, 5.0), 4)]
    layout = layout([sets], [[1, 1, 1, 1]])

    assert {:ok, attrs} =
             RestFitter.fit(request(%{"target_reps" => 50, "target_duration_sec" => 350}), layout)

    assert ordinary_pause_ms(attrs["events"], 4) == [25_000, 25_000, 25_000, 25_002]
  end

  test "returns the actual whole-second duration for a terminal gapless set and rejects fractional totals" do
    unbroken = layout([[set(20, 5.0, 5.0)]], [[]])

    assert {:ok, %{"target_duration_sec" => 100}} =
             RestFitter.fit(request(%{"target_duration_sec" => 105}), unbroken)

    fractional_terminal = layout([[set(20, 5.001, 5.001)]], [[]])

    assert {:error, {:total_not_whole_second, %{total_us: 100_020_000}}} =
             RestFitter.fit(request(%{"target_duration_sec" => 100}), fractional_terminal)
  end

  test "accepts a gapless phase ten seconds late and rejects one that is later" do
    request =
      request(%{
        "target_reps" => 18,
        "target_duration_sec" => 200,
        "timed_rests" => [%{"start_sec" => 100, "duration_sec" => 20}]
      })

    boundary = layout([[set(10, 11.0, 11.0)], [set(4, 8.0, 8.0), set(4, 8.0, 8.0)]], [[], [1]])
    assert {:ok, _} = RestFitter.fit(request, boundary)

    late = put_in(boundary, ["phases", Access.at(0), "sets"], [set(10, 12.0, 12.0)])
    assert {:error, {:phase_misses_anchor, %{phase: 1}}} = RestFitter.fit(request, late)
  end

  test "rejects malformed phase structure, weights, and timing" do
    request = request(%{"timed_rests" => [%{"start_sec" => 60, "duration_sec" => 10}]})
    one_phase = layout([[set(20, 5.0, 5.0)]], [[]])

    assert {:error, {:wrong_phase_count, %{expected: 2, actual: 1}}} =
             RestFitter.fit(request, one_phase)

    bad_weights = layout([[set(10, 5.0, 5.0), set(10, 5.0, 5.0)]], [[]])
    assert {:error, {:wrong_weight_count, _}} = RestFitter.fit(request(%{}), bad_weights)

    fractional = layout([[set(10, 5.0005, 5.0), set(10, 5.0, 5.0)]], [[1]])
    assert {:error, {:timing_not_whole_millisecond, _}} = RestFitter.fit(request(%{}), fractional)
  end

  property "genuinely feasible weighted layouts compile with exact anchors and preserved structure" do
    check all({request, layout} <- feasible_case(), max_runs: 300) do
      assert {:ok, attrs} = RestFitter.fit(request, layout)
      assert attrs["target_duration_sec"] == request.target_duration_sec
      definition = assert_valid_and_compiled(attrs)

      expected_sets = Enum.flat_map(layout["phases"], & &1["sets"])

      actual_sets =
        attrs["events"]
        |> Enum.filter(&(&1["kind"] == "work"))
        |> Enum.map(&Map.delete(&1, "kind"))

      assert actual_sets == expected_sets

      for rest <- request.timed_rests do
        assert {rest.start_sec * 1_000_000, rest.duration_sec * 1_000_000} in WorkoutRequest.rest_timeline(
                 definition.events
               )
      end

      assert_weighted_pause_oracle(attrs["events"], layout)
    end
  end

  property "a phase squeezed below its movement budget is infeasible" do
    check all({request, layout} <- feasible_case(), max_runs: 200) do
      squeezed = %{request | target_duration_sec: 1}
      assert {:error, {:phase_overfull, _}} = RestFitter.fit(squeezed, layout)
    end
  end

  # Every generated phase has a shared tail and a positive, equal-weight pause budget that
  # exceeds that tail. Anchors and total are derived after rounding the final ordinary pause
  # up to a whole second, so these are feasible inputs rather than permissive purported cases.
  defp feasible_case do
    gen all(
          phase_count <- integer(1..3),
          phases <- list_of(feasible_phase(), length: phase_count),
          fixed_durations <- list_of(integer(5..90), length: phase_count - 1)
        ) do
      {layout_phases, rests, total_ms, reps} =
        phases
        |> Enum.with_index()
        |> Enum.reduce({[], [], 0, 0}, fn {{sets, pauses, weights}, index},
                                          {layouts, rests, cursor, reps} ->
          movement = Enum.sum(Enum.map(sets, &movement_ms/1))
          end_ms = ceil_second(cursor + movement + Enum.sum(pauses))
          phase = %{"sets" => sets, "rest_weights" => weights}
          reps = reps + Enum.sum(Enum.map(sets, & &1["reps"]))

          case Enum.at(fixed_durations, index) do
            nil ->
              {[phase | layouts], rests, end_ms, reps}

            duration_sec ->
              duration_sec = max(duration_sec, div(tail_ms(List.last(sets)), 1000) + 1)
              rest = %{"start_sec" => div(end_ms, 1000), "duration_sec" => duration_sec}
              {[phase | layouts], [rest | rests], end_ms + duration_sec * 1000, reps}
          end
        end)

      {request(%{
         "target_reps" => reps,
         "target_duration_sec" => div(total_ms, 1000),
         "timed_rests" => Enum.reverse(rests)
       }),
       %{
         "name" => "Generated",
         "rationale" => "Feasible.",
         "phases" => Enum.reverse(layout_phases)
       }}
    end
  end

  defp feasible_phase do
    gen all(
          count <- integer(2..5),
          reps <- list_of(integer(1..15), length: count),
          active_ms <- integer(3_000..9_000),
          tail_ms <- integer(0..2_000),
          extra_ms <- integer(40_000..60_000),
          weights <- list_of(integer(1..5), length: count - 1)
        ) do
      sets = Enum.map(reps, &set(&1, (active_ms + tail_ms) / 1000, active_ms / 1000))
      # Each smallest weighted share exceeds the shared cadence tail by at least 40 seconds.
      {sets, Enum.map(weights, &(tail_ms + extra_ms * &1)), weights}
    end
  end

  defp assert_weighted_pause_oracle(events, %{"phases" => phases}) do
    Enum.reduce(Enum.with_index(phases), events, fn {phase, phase_index}, remaining_events ->
      gap_count = length(phase["sets"]) - 1
      phase_event_count = gap_count * 2 + 1
      {phase_events, remaining_events} = Enum.split(remaining_events, phase_event_count)
      actual_pauses = ordinary_pause_ms(phase_events, gap_count)
      assert actual_pauses == allocation_oracle(Enum.sum(actual_pauses), phase["rest_weights"])

      if phase_index == length(phases) - 1 do
        remaining_events
      else
        [_fixed_pause | after_fixed_pause] = remaining_events
        after_fixed_pause
      end
    end)

    :ok
  end

  # This deliberately uses integer arithmetic independent of fitter allocation. Generated
  # property weights are integers; decimal scale equivalence is covered by its direct test.
  defp allocation_oracle(total_ms, weights) do
    total_weight = Enum.sum(weights)
    floors = Enum.map(weights, &div(total_ms * &1, total_weight))
    List.update_at(floors, -1, &(&1 + total_ms - Enum.sum(floors)))
  end

  defp ordinary_pause_ms(events, gap_count) do
    events
    |> Enum.take(gap_count * 2)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [work, rest] ->
      cadence_tail_ms = round((work["sec_per_rep"] - work["sec_per_burpee"]) * 1_000)
      cadence_tail_ms + round(rest["duration_sec"] * 1_000)
    end)
  end

  defp movement_ms(set),
    do: round(((set["reps"] - 1) * set["sec_per_rep"] + set["sec_per_burpee"]) * 1000)

  defp tail_ms(set), do: round((set["sec_per_rep"] - set["sec_per_burpee"]) * 1000)
  defp ceil_second(milliseconds), do: div(milliseconds + 999, 1000) * 1000

  defp layout(phases, weights),
    do: %{
      "name" => "Test workout",
      "rationale" => "Test.",
      "phases" => Enum.zip_with(phases, weights, &%{"sets" => &1, "rest_weights" => &2})
    }

  defp assert_valid_and_compiled(attrs) do
    assert {:ok, definition} = WorkoutDefinition.new(attrs)
    assert {:ok, _} = PlanCompiler.compile(definition)
    definition
  end
end
