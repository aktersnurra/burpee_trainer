defmodule BurpeeTrainer.PlanCompiler.WorkoutDefinitionTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{Program, ProgramHash, WorkoutDefinition}
  alias BurpeeTrainer.TestFixtures.DeletionFirstFallback
  alias BurpeeTrainer.Workouts.Error

  test "accepts the exact version 1 definition and preserves ordered events" do
    attrs =
      valid_attrs(%{
        "events" => [
          %{
            "kind" => "work",
            "reps" => 5,
            "sec_per_rep" => 6.0,
            "sec_per_burpee" => 5.0
          },
          %{"kind" => "rest", "duration_sec" => 60},
          %{
            "kind" => "work",
            "reps" => 5,
            "sec_per_rep" => 6.0,
            "sec_per_burpee" => 6.0
          }
        ]
      })

    assert {:ok, definition} = WorkoutDefinition.new(attrs)

    assert Enum.map(definition.events, & &1.kind) == [:work, :rest, :work]
    assert WorkoutDefinition.canonical_map(definition)["events"] == attrs["events"]
  end

  test "rejects missing, unknown, and duplicate normalized definition or event fields" do
    for attrs <- [
          Map.delete(valid_attrs(), "name"),
          Map.put(valid_attrs(), "unknown", true),
          Map.put(valid_attrs(), :name, "duplicate"),
          put_in(valid_attrs(), ["events", Access.at(0), "unknown"], true),
          put_in(valid_attrs(), ["events", Access.at(0), :reps], 10)
        ] do
      assert {:error, %Error{code: :invalid_workout_definition}} =
               WorkoutDefinition.new(attrs)
    end
  end

  test "rejects definitions beyond the canonical JSON byte bound" do
    attrs = Map.put(valid_attrs(), "rationale", String.duplicate("a", 16_384))

    assert {:error,
            %Error{
              code: :invalid_workout_definition,
              context: %{field: :definition, value: :too_many_bytes}
            }} = WorkoutDefinition.new(attrs)
  end

  test "requires exact version and supported enum values" do
    for attrs <- [
          Map.put(valid_attrs(), "version", 2),
          Map.put(valid_attrs(), "burpee_type", "unknown"),
          Map.put(valid_attrs(), "pacing_style", "unknown"),
          put_in(valid_attrs(), ["events", Access.at(0), "kind"], "unknown")
        ] do
      assert {:error, %Error{code: :invalid_workout_definition}} =
               WorkoutDefinition.new(attrs)
    end
  end

  test "requires positive integer targets and non-empty events" do
    for attrs <- [
          Map.put(valid_attrs(), "target_duration_sec", 0),
          Map.put(valid_attrs(), "target_duration_sec", 120.0),
          Map.put(valid_attrs(), "target_reps", 0),
          Map.put(valid_attrs(), "target_reps", 10.0),
          Map.put(valid_attrs(), "events", [])
        ] do
      assert {:error, %Error{code: :invalid_workout_definition}} =
               WorkoutDefinition.new(attrs)
    end
  end

  test "requires positive event values and feasible work cadence" do
    for attrs <- [
          put_in(valid_attrs(), ["events", Access.at(0), "reps"], 0),
          put_in(valid_attrs(), ["events", Access.at(0), "sec_per_rep"], 0),
          put_in(valid_attrs(), ["events", Access.at(0), "sec_per_burpee"], 0),
          put_in(valid_attrs(), ["events", Access.at(0), "sec_per_burpee"], 12.1),
          Map.put(valid_attrs(), "events", [%{"kind" => "rest", "duration_sec" => 0}])
        ] do
      assert {:error, %Error{code: :invalid_workout_definition}} =
               WorkoutDefinition.new(attrs)
    end
  end

  test "rejects positive event values that disappear in canonical runtime units" do
    sub_microsecond_work =
      valid_attrs(%{
        "target_duration_sec" => 1,
        "target_reps" => 1,
        "events" => [
          %{
            "kind" => "work",
            "reps" => 1,
            "sec_per_rep" => 1.0,
            "sec_per_burpee" => 0.0000004
          }
        ]
      })

    sub_millisecond_rest =
      valid_attrs(%{
        "target_duration_sec" => 1,
        "target_reps" => 1,
        "events" => [
          %{
            "kind" => "work",
            "reps" => 1,
            "sec_per_rep" => 1.0,
            "sec_per_burpee" => 0.5
          },
          %{"kind" => "rest", "duration_sec" => 0.0004}
        ]
      })

    for attrs <- [sub_microsecond_work, sub_millisecond_rest] do
      assert {:error, %Error{code: :invalid_workout_definition}} =
               WorkoutDefinition.new(attrs)
    end
  end

  test "compiler validates duration in the same canonical units executed by Work/Rest" do
    attrs =
      valid_attrs(%{
        "target_duration_sec" => 1,
        "target_reps" => 2,
        "events" => [
          %{
            "kind" => "work",
            "reps" => 1,
            "sec_per_rep" => 0.499,
            "sec_per_burpee" => 0.499
          },
          %{"kind" => "rest", "duration_sec" => 0.0006},
          %{
            "kind" => "work",
            "reps" => 1,
            "sec_per_rep" => 0.5,
            "sec_per_burpee" => 0.5
          }
        ]
      })

    assert {:ok, definition} = WorkoutDefinition.new(attrs)
    assert {:ok, program} = PlanCompiler.compile(definition)

    assert [work, rest, terminal_work] = ProgramHash.canonical_map(program)["events"]
    assert work["sec_per_rep_us"] == 499_000
    assert rest["duration_ms"] == 1
    assert terminal_work["duration_sec"] == 0.5
  end

  test "requires exact event rep totals" do
    attrs = put_in(valid_attrs(), ["events", Access.at(0), "reps"], 9)

    assert {:error,
            %Error{
              code: :invalid_workout_definition,
              context: %{field: :target_reps, value: %{actual: 9, expected: 10}}
            }} = WorkoutDefinition.new(attrs)
  end

  test "requires exact duration arithmetic without hidden padding or pace stretching" do
    attrs =
      valid_attrs(%{
        "events" => [
          %{
            "kind" => "work",
            "reps" => 10,
            "sec_per_rep" => 11.9,
            "sec_per_burpee" => 11.9
          }
        ]
      })

    assert {:error,
            %Error{
              code: :invalid_workout_definition,
              context: %{
                field: :target_duration_sec,
                value: %{actual_us: 119_000_000, expected_us: 120_000_000}
              }
            }} = WorkoutDefinition.new(attrs)
  end

  test "canonical definition map and hash match the frozen fallback fixture byte for byte" do
    assert {:ok, definition} = WorkoutDefinition.new(DeletionFirstFallback.definition_json())

    assert WorkoutDefinition.canonical_map(definition) ==
             DeletionFirstFallback.definition_json()

    assert WorkoutDefinition.hash(definition) == DeletionFirstFallback.definition_hash()
  end

  test "compiler emits the frozen terminal-active fallback at exactly 120 seconds" do
    assert {:ok, definition} = WorkoutDefinition.new(DeletionFirstFallback.definition_json())
    assert {:ok, program} = PlanCompiler.compile(definition)
    assert [work] = Program.events(program)

    assert program.target_duration_sec == 120
    assert Program.duration_sec(program) == 120.0
    assert work.duration_sec == 120.0

    assert work.duration_sec ==
             (work.reps - 1) * work.sec_per_rep + work.sec_per_burpee

    assert ProgramHash.canonical_map(program) == DeletionFirstFallback.program_json()
    assert ProgramHash.hash(program) == DeletionFirstFallback.content_hash()
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "name" => "Built-in Steady 10",
        "burpee_type" => "six_count",
        "target_duration_sec" => 120,
        "target_reps" => 10,
        "pacing_style" => "even",
        "rationale" => "A steady reusable fallback that works without provider credentials.",
        "events" => [
          %{
            "kind" => "work",
            "reps" => 10,
            "sec_per_rep" => 12.0,
            "sec_per_burpee" => 12.0
          }
        ]
      },
      overrides
    )
  end
end
