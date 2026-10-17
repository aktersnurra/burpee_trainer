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

  defp sec(seconds), do: %{"sec" => seconds}
  defp share(weight), do: %{"share" => weight}

  test "a share takes the time left after the sets and their cadence tails" do
    # 10 reps of 6 s (5 s moving): 59 s of movement and a 1 s tail before the gap.
    layout = layout([[set(10, 6.0, 5.0), set(10, 6.0, 5.0)]], [[share(1)]])

    assert {:ok, attrs} = RestFitter.fit(request(%{"target_duration_sec" => 140}), layout)
    assert rests(attrs) == [21.0]
    assert attrs["target_duration_sec"] == 140
    assert_valid_and_compiled(attrs)
  end

  test "an exact rest is that many seconds after the beat, and shares take what is left" do
    # Three sets of 10 at 10 s per rep (3 s moving): 93 s of movement each, 7 s tails.
    sets = List.duplicate(set(10, 10.0, 3.0), 3)

    assert {:ok, attrs} =
             RestFitter.fit(
               request(%{"target_reps" => 30, "target_duration_sec" => 373}),
               layout([sets], [[sec(20), share(1)]])
             )

    assert rests(attrs) == [20.0, 60.0]
  end

  test "a phase of exact rests ends exactly at its target or says by how much it misses" do
    sets = List.duplicate(set(10, 10.0, 3.0), 3)
    request = request(%{"target_reps" => 30, "target_duration_sec" => 373})

    assert {:ok, attrs} = RestFitter.fit(request, layout([sets], [[sec(20), sec(60)]]))
    assert rests(attrs) == [20.0, 60.0]

    assert {:error,
            {:phase_misses_anchor,
             %{phase: 1, end_us: 365_000_000, target_us: 373_000_000, adjustable: true}}} =
             RestFitter.fit(request, layout([sets], [[sec(20), sec(52)]]))

    assert {:error,
            {:phase_overfull, %{phase: 1, needed_us: 381_000_000, available_us: 373_000_000}}} =
             RestFitter.fit(request, layout([sets], [[sec(20), sec(68)]]))
  end

  test "sec 0 runs the next set on the next beat, with no rest event" do
    sets = [set(4, 10.0, 3.0), set(3, 10.0, 3.0)]

    request =
      request(%{"target_reps" => 7, "target_duration_sec" => 63, "recovery" => "optional"})

    assert {:ok, attrs} = RestFitter.fit(request, layout([sets], [[sec(0)]]))
    assert Enum.map(attrs["events"], & &1["kind"]) == ["work", "work"]
    definition = assert_valid_and_compiled(attrs)
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    unbroken = [set(4, 5.0, 5.0), set(3, 5.0, 5.0)]

    assert {:ok, %{"events" => [_, _]}} =
             RestFitter.fit(
               request(%{"target_reps" => 7, "target_duration_sec" => 35}),
               layout([unbroken], [[sec(0)]])
             )
  end

  test "shares that would have to be negative report what the phase needs" do
    layout = layout([[set(15, 5.0, 5.0), set(15, 5.0, 5.0)]], [[share(1)]])

    assert {:error,
            {:phase_overfull, %{phase: 1, needed_us: 150_000_000, available_us: 120_000_000}}} =
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
        [List.duplicate(share(1), 9), List.duplicate(share(1), 5), [share(1)]]
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

    layout = layout([[set(10, 9.0, 9.0)], [set(5, 8.0, 8.0), set(5, 8.0, 8.0)]], [[], [share(1)]])
    assert {:ok, _} = RestFitter.fit(request, layout)

    too_early = put_in(layout, ["phases", Access.at(0), "sets"], [set(10, 8.0, 8.0)])

    assert {:error, {:phase_misses_anchor, %{phase: 1, adjustable: false}}} =
             RestFitter.fit(request, too_early)
  end

  test "a timed rest shorter than the cadence tail before it is refused" do
    fixed_pause_shorter_than_tail =
      layout([[set(10, 7.0, 5.0)], [set(5, 8.0, 8.0), set(5, 8.0, 8.0)]], [[], [share(1)]])

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
      layout = layout([[set(10, cadence, 5.0), set(10, 5.0, 5.0)]], [[share(1)]])

      assert {:error, {:timing_not_whole_millisecond, %{phase: 1, value: ^cadence}}} =
               RestFitter.fit(request(%{}), layout)
    end

    off_grid_rest = layout([[set(10, 5.0, 5.0), set(10, 5.0, 5.0)]], [[sec(20.0005)]])

    assert {:error, {:timing_not_whole_millisecond, %{phase: 1, value: 20.0005}}} =
             RestFitter.fit(request(%{}), off_grid_rest)
  end

  test "returns phase_overfull for huge whole-grid integer and float cadence values" do
    for cadence <- [Integer.pow(10, 306), 1.0e308] do
      layout = layout([[set(10, cadence, 5), set(10, 5, 5)]], [[share(1)]])
      assert {:error, {:phase_overfull, %{phase: 1}}} = RestFitter.fit(request(%{}), layout)
    end
  end

  test "allocates decimal-equivalent and extreme shares without float drift or overflow" do
    sets = List.duplicate(set(10, 5.0, 5.0), 4)
    integer_shares = layout([sets], [[share(1), share(3), share(2)]])
    decimal_shares = layout([sets], [[share(0.1), share(0.3), share(0.2)]])

    request = request(%{"target_reps" => 40, "target_duration_sec" => 280})
    assert {:ok, integer_attrs} = RestFitter.fit(request, integer_shares)
    assert {:ok, decimal_attrs} = RestFitter.fit(request, decimal_shares)
    assert rests(integer_attrs) == [13.333, 40.0, 26.667]
    assert rests(decimal_attrs) == [13.333, 40.0, 26.667]

    two_sets = layout([[set(10, 5.0, 5.0), set(10, 5.0, 5.0)]], [[share(1.0e308)]])
    assert {:ok, attrs} = RestFitter.fit(request(%{}), two_sets)
    assert rests(attrs) == [20.0]
  end

  test "puts the rounding remainder on the last share, never on an exact rest" do
    sets = [set(10, 5.0, 4.998) | List.duplicate(set(10, 5.0, 5.0), 4)]
    layout = layout([sets], [[share(1), share(1), share(1), sec(10)]])

    # 250 s of sets and tails, then the exact 10 s: 91 s left for three equal shares.
    assert {:ok, attrs} =
             RestFitter.fit(request(%{"target_reps" => 50, "target_duration_sec" => 351}), layout)

    assert rests(attrs) == [30.333, 30.333, 30.334, 10.0]
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

    boundary =
      layout([[set(10, 11.0, 11.0)], [set(4, 8.0, 8.0), set(4, 8.0, 8.0)]], [[], [share(1)]])

    assert {:ok, _} = RestFitter.fit(request, boundary)

    late = put_in(boundary, ["phases", Access.at(0), "sets"], [set(10, 12.0, 12.0)])
    assert {:error, {:phase_misses_anchor, %{phase: 1}}} = RestFitter.fit(request, late)
  end

  test "rejects malformed phase structure, rests, and timing" do
    request = request(%{"timed_rests" => [%{"start_sec" => 60, "duration_sec" => 10}]})
    one_phase = layout([[set(20, 5.0, 5.0)]], [[]])

    assert {:error, {:wrong_phase_count, %{expected: 2, actual: 1}}} =
             RestFitter.fit(request, one_phase)

    two_sets = [set(10, 5.0, 5.0), set(10, 5.0, 5.0)]

    assert {:error, {:wrong_rest_count, %{phase: 1, sets: 2, rests: 0}}} =
             RestFitter.fit(request(%{}), layout([two_sets], [[]]))

    for bad <- [
          %{},
          %{"sec" => 1, "share" => 1},
          %{"sec" => -1},
          %{"share" => 0},
          5,
          %{"sec" => "5"}
        ] do
      assert {:error, {:invalid_rest, %{phase: 1, gap: 1}}} =
               RestFitter.fit(request(%{}), layout([two_sets], [[bad]])),
             "accepted #{inspect(bad)}"
    end

    fractional = layout([[set(10, 5.0005, 5.0), set(10, 5.0, 5.0)]], [[share(1)]])
    assert {:error, {:timing_not_whole_millisecond, _}} = RestFitter.fit(request(%{}), fractional)
  end

  describe "describe/1 says what to change" do
    test "an overfull phase names its parts, its anchor and what to change" do
      sets = List.duplicate(set(10, 10.0, 3.0), 3)
      request = request(%{"target_reps" => 30, "target_duration_sec" => 373})

      {:error, reason} = RestFitter.fit(request, layout([sets], [[sec(20), sec(68)]]))
      message = RestFitter.describe(reason)

      assert message =~ "phase 1 needs 6:21"
      assert message =~ "target_duration_sec (6:13)"
      assert message =~ "4:39 of sets"
      assert message =~ "14 s of cadence tails"
      assert message =~ "1:28 of exact rests"
      assert message =~ "8 s"
    end

    test "a short phase of exact rests says by how much and how to fill it" do
      sets = List.duplicate(set(10, 10.0, 3.0), 3)
      request = request(%{"target_reps" => 30, "target_duration_sec" => 373})

      {:error, reason} = RestFitter.fit(request, layout([sets], [[sec(20), sec(52)]]))
      message = RestFitter.describe(reason)

      assert message =~ "end at 6:05, 8 s before target_duration_sec (6:13)"
      assert message =~ ~s({"share": 1})
    end

    test "a phase ending at a timed rest names that rest, not the workout's length" do
      request =
        request(%{
          "target_reps" => 20,
          "target_duration_sec" => 200,
          "timed_rests" => [%{"start_sec" => 100, "duration_sec" => 20}]
        })

      layout =
        layout([[set(5, 10.0, 3.0), set(5, 10.0, 3.0)], [set(10, 8.0, 8.0)]], [[sec(90)], []])

      {:error, reason} = RestFitter.fit(request, layout)
      assert RestFitter.describe(reason) =~ "the timed rest at 1:40"
    end

    test "a single set off its target explains that the last beat's tail is not counted" do
      # 60 reps, one every 20 s with 4 s moving: the workout ends at 19:44.
      layout = layout([[set(60, 20.0, 4.0)]], [[]])

      {:error, reason} =
        RestFitter.fit(request(%{"target_reps" => 60, "target_duration_sec" => 1200}), layout)

      message = RestFitter.describe(reason)
      assert message =~ "ends at 19:44, 16 s before target_duration_sec (20:00)"
      assert message =~ "the 16 s after the last rep is not part of the workout"
      assert message =~ "target_duration_sec 1184"
    end
  end

  property "feasible layouts of shares and exact rests compile with exact anchors and preserved structure" do
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

      assert_rest_oracle(attrs["events"], layout)
    end
  end

  property "a phase squeezed below its movement budget is infeasible" do
    check all({request, layout} <- feasible_case(), max_runs: 200) do
      squeezed = %{request | target_duration_sec: 1}
      assert {:error, {:phase_overfull, _}} = RestFitter.fit(squeezed, layout)
    end
  end

  # Every generated phase has a shared tail, some exact rests and at least one share. Anchors
  # and the total are derived after rounding each phase end up to a whole second, so the
  # shares absorb that rounding and these are feasible inputs, not permissive ones.
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
          phase = %{"sets" => sets, "rests" => weights}
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
          specs <-
            list_of(one_of([integer(1..5), map(integer(1..90), &{:sec, &1})]),
              length: count - 1
            ),
          share_at <- integer(0..(count - 2))
        ) do
      sets = Enum.map(reps, &set(&1, (active_ms + tail_ms) / 1000, active_ms / 1000))
      # At least one share, so the phase can always reach its whole-second anchor.
      specs = List.update_at(specs, share_at, &if(is_integer(&1), do: &1, else: 1))

      rests =
        Enum.map(specs, fn
          {:sec, seconds} -> sec(seconds)
          weight -> share(weight)
        end)

      # A share gets at least 40 s per weight; an exact rest is what it says. Both follow the tail.
      pauses =
        Enum.map(specs, fn
          {:sec, seconds} -> tail_ms + seconds * 1000
          weight -> tail_ms + 40_000 * weight
        end)

      {sets, pauses, rests}
    end
  end

  defp assert_rest_oracle(events, %{"phases" => phases}) do
    Enum.reduce(Enum.with_index(phases), events, fn {phase, phase_index}, remaining_events ->
      gap_count = length(phase["sets"]) - 1
      phase_event_count = gap_count * 2 + 1
      {phase_events, remaining_events} = Enum.split(remaining_events, phase_event_count)
      actual = visible_rest_ms(phase_events, gap_count)

      {exact, shares} =
        phase["rests"]
        |> Enum.zip(actual)
        |> Enum.split_with(fn {spec, _ms} -> Map.has_key?(spec, "sec") end)

      for {%{"sec" => seconds}, ms} <- exact, do: assert(ms == seconds * 1000)

      share_ms = Enum.map(shares, &elem(&1, 1))
      weights = Enum.map(shares, fn {%{"share" => weight}, _ms} -> weight end)
      assert share_ms == allocation_oracle(Enum.sum(share_ms), weights)

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

  defp visible_rest_ms(events, gap_count) do
    events
    |> Enum.take(gap_count * 2)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [_work, rest] -> round(rest["duration_sec"] * 1_000) end)
  end

  defp rests(attrs),
    do: for(%{"kind" => "rest", "duration_sec" => seconds} <- attrs["events"], do: seconds)

  defp movement_ms(set),
    do: round(((set["reps"] - 1) * set["sec_per_rep"] + set["sec_per_burpee"]) * 1000)

  defp tail_ms(set), do: round((set["sec_per_rep"] - set["sec_per_burpee"]) * 1000)
  defp ceil_second(milliseconds), do: div(milliseconds + 999, 1000) * 1000

  defp layout(phases, rests),
    do: %{
      "name" => "Test workout",
      "rationale" => "Test.",
      "phases" => Enum.zip_with(phases, rests, &%{"sets" => &1, "rests" => &2})
    }

  defp assert_valid_and_compiled(attrs) do
    assert {:ok, definition} = WorkoutDefinition.new(attrs)
    assert {:ok, _} = PlanCompiler.compile(definition)
    definition
  end
end
