defmodule BurpeeTrainer.Coach.WorkoutRequestTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.WorkoutRequest
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.Error

  @request %{
    "burpee_type" => "six_count",
    "target_reps" => 140,
    "target_duration_sec" => 1_200,
    "pacing_style" => "unbroken",
    "recovery" => "required",
    "timed_rests" => [
      %{"start_sec" => 660, "duration_sec" => 60},
      %{"start_sec" => 1_080, "duration_sec" => 30}
    ],
    "requested_pace_sec" => nil
  }

  test "validates concrete targets and exact rest anchors" do
    assert {:ok, request} = WorkoutRequest.new(@request)
    assert request.target_reps == 140
    assert request.target_duration_sec == 1_200

    assert request.timed_rests == [
             %{start_sec: 660, duration_sec: 60},
             %{start_sec: 1_080, duration_sec: 30}
           ]

    assert WorkoutRequest.to_map(request) == @request
  end

  test "rejects missing targets and overlapping or out-of-range rests" do
    invalid = [
      Map.delete(@request, "target_reps"),
      Map.put(@request, "target_reps", 0),
      Map.put(@request, "timed_rests", [%{"start_sec" => 1_190, "duration_sec" => 30}]),
      Map.put(@request, "timed_rests", [
        %{"start_sec" => 660, "duration_sec" => 60},
        %{"start_sec" => 700, "duration_sec" => 30}
      ]),
      Map.put(@request, "recovery", "forbidden")
    ]

    for attrs <- invalid do
      assert {:error, %Error{code: :invalid_workout_definition}} = WorkoutRequest.new(attrs)
    end
  end

  test "rejects a timed rest starting more than ten seconds from its confirmed time" do
    assert {:ok, request} = WorkoutRequest.new(@request)
    assert {:ok, definition} = WorkoutDefinition.new(anchored_definition())
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    mistimed =
      anchored_definition()
      |> put_in(["events", Access.at(1), "duration_sec"], 121)
      |> put_in(["events", Access.at(5), "duration_sec"], 289)

    assert {:ok, mistimed} = WorkoutDefinition.new(mistimed)

    assert {:error, %Error{code: :invalid_workout_definition}, detail} =
             WorkoutRequest.validate_definition(request, mistimed)

    assert detail =~ "start_sec=660"
  end

  test "accepts at most ten seconds of elapsed and rest-start drift, never rest-duration drift" do
    assert {:ok, request} = WorkoutRequest.new(@request)

    within_limit =
      anchored_definition()
      |> put_in(["events", Access.at(1), "duration_sec"], 115)
      |> put_in(["events", Access.at(5), "duration_sec"], 305)
      |> Map.put("target_duration_sec", 1_210)

    assert {:ok, definition} = WorkoutDefinition.new(within_limit)
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    too_long =
      anchored_definition()
      |> put_in(["events", Access.at(1), "duration_sec"], 121)
      |> Map.put("target_duration_sec", 1_211)

    assert {:ok, definition} = WorkoutDefinition.new(too_long)

    assert {:error, %Error{code: :invalid_workout_definition}, detail} =
             WorkoutRequest.validate_definition(request, definition)

    assert detail =~ "confirmed_target_duration_sec"

    late_anchor =
      anchored_definition()
      |> put_in(["events", Access.at(1), "duration_sec"], 121)
      |> put_in(["events", Access.at(5), "duration_sec"], 289)

    assert {:ok, definition} = WorkoutDefinition.new(late_anchor)

    assert {:error, %Error{code: :invalid_workout_definition}, detail} =
             WorkoutRequest.validate_definition(request, definition)

    assert detail =~ "start_sec=660"

    wrong_rest_duration =
      anchored_definition()
      |> put_in(["events", Access.at(3), "duration_sec"], 65)
      |> put_in(["events", Access.at(5), "duration_sec"], 295)

    assert {:ok, definition} = WorkoutDefinition.new(wrong_rest_duration)

    assert {:error, %Error{code: :invalid_workout_definition}, detail} =
             WorkoutRequest.validate_definition(request, definition)

    assert detail =~ "duration_sec=60"
  end

  test "confirmed targets override a self-consistent but incorrect provider plan" do
    assert {:ok, request} = WorkoutRequest.new(@request)

    wrong =
      anchored_definition()
      |> Map.put("target_reps", 280)
      |> Map.put("target_duration_sec", 1_260)
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 280, "sec_per_rep" => 4.5, "sec_per_burpee" => 4.5}
      ])

    assert {:ok, wrong} = WorkoutDefinition.new(wrong)

    assert {:error, %Error{code: :invalid_workout_definition}, detail} =
             WorkoutRequest.validate_definition(request, wrong)

    assert detail =~ "confirmed_target_reps actual=280 expected=140"
  end

  test "required recovery cannot be a rest only before all work" do
    {:ok, request} =
      @request
      |> Map.put("target_reps", 10)
      |> Map.put("target_duration_sec", 120)
      |> Map.put("timed_rests", [])
      |> WorkoutRequest.new()

    proposal = %{
      "version" => 1,
      "name" => "Rest first only",
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "unbroken",
      "rationale" => "A rest before one unbroken work set.",
      "events" => [
        %{"kind" => "rest", "duration_sec" => 10},
        %{"kind" => "work", "reps" => 10, "sec_per_rep" => 11, "sec_per_burpee" => 11}
      ]
    }

    assert {:ok, definition} = WorkoutDefinition.new(proposal)

    assert {:error, %Error{code: :invalid_workout_definition}, detail} =
             WorkoutRequest.validate_definition(request, definition)

    assert detail =~ "between_set_recovery"
  end

  test "total pauses include Even cadence tails and adjoining rest fragments" do
    attrs =
      @request
      |> Map.merge(%{
        "target_reps" => 4,
        "target_duration_sec" => 27,
        "pacing_style" => "even",
        "recovery" => "required",
        "timed_rests" => [%{"start_sec" => 11, "duration_sec" => 5}],
        "requested_pace_sec" => 5
      })

    {:ok, request} = WorkoutRequest.new(attrs)
    work = %{"kind" => "work", "reps" => 2, "sec_per_rep" => 6, "sec_per_burpee" => 5}

    proposal =
      anchored_definition()
      |> Map.merge(%{
        "target_reps" => 4,
        "target_duration_sec" => 27,
        "pacing_style" => "even",
        "events" => [work, %{"kind" => "rest", "duration_sec" => 4}, work]
      })

    {:ok, definition} = WorkoutDefinition.new(proposal)
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    {:ok, naive} =
      WorkoutRequest.new(
        Map.put(attrs, "timed_rests", [%{"start_sec" => 12, "duration_sec" => 4}])
      )

    assert {:error, _, _} = WorkoutRequest.validate_definition(naive, definition)

    fragmented =
      anchored_definition()
      |> Map.update!("events", fn events ->
        List.insert_at(events, 4, %{"kind" => "rest", "duration_sec" => 5})
      end)
      |> put_in(["events", Access.at(6), "duration_sec"], 295)

    {:ok, original} = WorkoutRequest.new(@request)
    {:ok, definition} = WorkoutDefinition.new(fragmented)
    assert {:error, _, _} = WorkoutRequest.validate_definition(original, definition)
  end

  test "Even active pace does not force start-to-start cadence" do
    attrs =
      @request
      |> Map.merge(%{
        "target_reps" => 10,
        "target_duration_sec" => 60,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => 5
      })

    {:ok, request} = WorkoutRequest.new(attrs)

    proposal =
      anchored_definition()
      |> Map.merge(%{
        "target_reps" => 10,
        "target_duration_sec" => 59,
        "pacing_style" => "even",
        "events" => [%{"kind" => "work", "reps" => 10, "sec_per_rep" => 6, "sec_per_burpee" => 5}]
      })

    {:ok, definition} = WorkoutDefinition.new(proposal)
    assert :ok = WorkoutRequest.validate_definition(request, definition)
  end

  test "ordered supplied sets cannot be replaced by a different rep partition" do
    attrs = @request |> Map.merge(%{"set_reps" => [88, 22, 10, 2, 18]})
    assert {:ok, request} = WorkoutRequest.new(attrs)
    {:ok, definition} = WorkoutDefinition.new(anchored_definition())
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    changed =
      anchored_definition()
      |> put_in(["events", Access.at(0), "reps"], 87)
      |> put_in(["events", Access.at(2), "reps"], 23)

    {:ok, definition} = WorkoutDefinition.new(changed)
    assert {:error, _, detail} = WorkoutRequest.validate_definition(request, definition)
    assert detail =~ "set_configuration"
  end

  test "a limit on set size is kept, one past the reps is dropped, and no set may pass it" do
    assert {:ok, request} = WorkoutRequest.new(Map.put(@request, "max_set_reps", 88))
    assert request.max_set_reps == 88
    assert WorkoutRequest.to_map(request)["max_set_reps"] == 88

    # Without one it is absent from the map, and null is the same as absent.
    assert {:ok, %{max_set_reps: nil} = unlimited} =
             WorkoutRequest.new(Map.put(@request, "max_set_reps", nil))

    refute Map.has_key?(WorkoutRequest.to_map(unlimited), "max_set_reps")

    for bad <- [0, -5, 2.5, "88"],
        do: assert({:error, _} = WorkoutRequest.new(Map.put(@request, "max_set_reps", bad)))

    # A limit at or above the whole workout limits nothing, so it is dropped, not refused.
    assert {:ok, %{max_set_reps: nil}} =
             WorkoutRequest.new(Map.put(@request, "max_set_reps", 141))

    # The anchored fixture's longest set is 88 reps.
    {:ok, definition} = WorkoutDefinition.new(anchored_definition())
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    {:ok, tight} = WorkoutRequest.new(Map.put(@request, "max_set_reps", 50))
    assert {:error, _, detail} = WorkoutRequest.validate_definition(tight, definition)
    assert detail =~ "max_set_reps"
  end

  defp anchored_definition do
    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    %{
      "version" => 1,
      "name" => "Confirmed anchor fixture",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "rationale" => "Work, with explicit recovery at 11 and 18 minutes.",
      "events" => [
        work.(88),
        rest.(110),
        work.(22),
        rest.(60),
        work.(10),
        rest.(300),
        work.(2),
        rest.(30),
        work.(18)
      ]
    }
  end
end
