defmodule BurpeeTrainer.Coach.PhasedWorkoutDefinitionTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.{PhasedWorkoutDefinition, WorkoutRequest}
  alias BurpeeTrainer.PlanCompiler.{WorkoutDefinition, Program}
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.Workouts.Error

  test "two confirmed anchors require typed rests and preserve model-chosen set recovery" do
    request =
      request([
        %{"start_sec" => 660, "duration_sec" => 60},
        %{"start_sec" => 1_080, "duration_sec" => 30}
      ])

    schema = PhasedWorkoutDefinition.json_schema(request)
    assert PhasedWorkoutDefinition.phase_budgets(request) == [660, 360, 90]

    assert Enum.all?(~w[phase_1 rest_1 phase_2 rest_2 phase_3], &(&1 in schema["required"]))
    assert schema["properties"]["rest_1"]["properties"]["duration_sec"]["enum"] == [60]
    assert schema["properties"]["rest_2"]["properties"]["duration_sec"]["enum"] == [30]
    refute Map.has_key?(schema["properties"], "events")

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    proposal = %{
      "version" => 1,
      "name" => "Phased recovery",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "rationale" => "Recovery between unbroken sets.",
      "phase_1" => %{
        "work_rest_pairs" => [%{"work" => work.(88), "rest_after" => rest.(110)}],
        "last_work" => work.(22)
      },
      "rest_1" => rest.(60),
      "phase_2" => %{
        "work_rest_pairs" => [%{"work" => work.(10), "rest_after" => rest.(300)}],
        "last_work" => work.(2)
      },
      "rest_2" => rest.(30),
      "phase_3" => %{"work_rest_pairs" => [], "last_work" => work.(18)}
    }

    assert {:ok, flattened} = PhasedWorkoutDefinition.flatten(request, proposal)

    assert Enum.map(flattened["events"], & &1["kind"]) ==
             ~w[work rest work rest work rest work rest work]

    assert {:ok, definition} = WorkoutDefinition.new(flattened)
    assert {:ok, %Program{}} = PlanCompiler.compile(definition)
    assert :ok = WorkoutRequest.validate_definition(request, definition)

    broken = put_in(proposal, ["phase_1", "work_rest_pairs"], [%{"work" => work.(88)}])

    assert {:error, %Error{code: :invalid_workout_definition}} =
             PhasedWorkoutDefinition.flatten(request, broken)
  end

  test "required recovery without fixed times still requires a rest, while no-rest stays flat" do
    required = request([])
    schema = PhasedWorkoutDefinition.json_schema(required)
    assert Enum.all?(~w[phase_1 rest_1 phase_2], &(&1 in schema["required"]))
    refute Map.has_key?(schema["properties"]["rest_1"]["properties"]["duration_sec"], "enum")
    assert PhasedWorkoutDefinition.use_phases?(required)

    {:ok, forbidden} =
      WorkoutRequest.new(%{request_attrs([]) | "recovery" => "forbidden"})

    refute PhasedWorkoutDefinition.use_phases?(forbidden)
  end

  test "optional Unbroken recovery uses typed rests only when active work leaves a recovery pool" do
    attrs =
      Map.merge(request_attrs([]), %{
        "recovery" => "optional",
        "target_reps" => 145,
        "requested_pace_sec" => 5,
        "set_reps" => List.duplicate(8, 5) ++ List.duplicate(7, 15)
      })

    {:ok, request} = WorkoutRequest.new(attrs)
    assert PhasedWorkoutDefinition.use_phases?(request)
    schema = PhasedWorkoutDefinition.json_schema(request)
    assert Enum.all?(~w[phase_1 rest_1 phase_2], &(&1 in schema["required"]))

    for override <- [
          %{"pacing_style" => "even"},
          %{"target_duration_sec" => 725},
          %{"requested_pace_sec" => nil},
          %{"set_reps" => [145]}
        ] do
      {:ok, flat} = WorkoutRequest.new(Map.merge(attrs, override))
      refute PhasedWorkoutDefinition.use_phases?(flat)
    end
  end

  test "phase repair feedback exposes the compiler's millisecond rounding deficit" do
    attrs =
      Map.merge(
        request_attrs([
          %{"start_sec" => 300, "duration_sec" => 60},
          %{"start_sec" => 600, "duration_sec" => 60}
        ]),
        %{
          "target_reps" => 145,
          "requested_pace_sec" => 5,
          "set_reps" => List.duplicate(8, 5) ++ List.duplicate(7, 15)
        }
      )

    {:ok, request} = WorkoutRequest.new(attrs)

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    phase = fn reps, pauses ->
      %{
        "work_rest_pairs" =>
          Enum.zip(Enum.drop(reps, -1), pauses)
          |> Enum.map(fn {reps, seconds} ->
            %{"work" => work.(reps), "rest_after" => rest.(seconds)}
          end),
        "last_work" => work.(List.last(reps))
      }
    end

    proposal = %{
      "version" => 1,
      "name" => "Millisecond recovery",
      "burpee_type" => "six_count",
      "target_reps" => 145,
      "target_duration_sec" => 1200,
      "pacing_style" => "unbroken",
      "rationale" => "Exact fixed pauses and balanced flexible recovery.",
      "phase_1" => phase.(List.duplicate(8, 5), List.duplicate(25, 4)),
      "rest_1" => rest.(60),
      "phase_2" => phase.(List.duplicate(7, 5), List.duplicate(16.25, 4)),
      "rest_2" => rest.(60),
      "phase_3" => phase.(List.duplicate(7, 10), List.duplicate(21.111111, 8) ++ [21.111112])
    }

    assert {:ok, flattened} = PhasedWorkoutDefinition.flatten(request, proposal)

    assert {:error,
            %Error{context: %{value: %{actual_us: 1_199_999_000, expected_us: 1_200_000_000}}}} =
             WorkoutDefinition.new(flattened)

    assert PhasedWorkoutDefinition.phase_feedback(request, proposal) ==
             " phase_seconds=[300, 240, 539.999] expected=[300, 240, 540]"

    corrected =
      put_in(
        proposal,
        ["phase_3", "work_rest_pairs", Access.at(8), "rest_after", "duration_sec"],
        21.112
      )

    assert {:ok, flattened} = PhasedWorkoutDefinition.flatten(request, corrected)
    assert {:ok, definition} = WorkoutDefinition.new(flattened)
    assert {:ok, %Program{}} = PlanCompiler.compile(definition)
    assert :ok = WorkoutRequest.validate_definition(request, definition)
  end

  defp request(rests) do
    {:ok, request} = WorkoutRequest.new(request_attrs(rests))
    request
  end

  defp request_attrs(rests) do
    %{
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "recovery" => "required",
      "timed_rests" => rests,
      "requested_pace_sec" => nil
    }
  end
end
