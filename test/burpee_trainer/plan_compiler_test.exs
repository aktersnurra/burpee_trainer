defmodule BurpeeTrainer.PlanCompilerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent, ProgramHash, WorkoutDefinition}

  test "compiles a canonical definition into schema three solver one events" do
    definition =
      definition!(%{
        "target_reps" => 2,
        "target_duration_sec" => 20,
        "events" => [
          %{
            "kind" => "work",
            "reps" => 2,
            "sec_per_rep" => 15.0,
            "sec_per_burpee" => 5.0
          }
        ]
      })

    assert {:ok, %Program{} = program} = PlanCompiler.compile(definition)
    assert program.schema_version == 3
    assert program.solver_version == 1
    assert Program.total_reps(program) == 2
    assert Program.duration_sec(program) == 20.0

    assert [%ProgramEvent.Work{duration_sec: 20.0}] = program.events

    assert ProgramHash.canonical_map(program)["semantics"]["definition_hash"] ==
             WorkoutDefinition.hash(definition)
  end

  test "preserves rest boundaries and ends with terminal active work" do
    definition =
      definition!(%{
        "target_reps" => 4,
        "target_duration_sec" => 40,
        "events" => [
          %{
            "kind" => "work",
            "reps" => 2,
            "sec_per_rep" => 8.0,
            "sec_per_burpee" => 5.0
          },
          %{"kind" => "rest", "duration_sec" => 10},
          %{
            "kind" => "work",
            "reps" => 2,
            "sec_per_rep" => 9.0,
            "sec_per_burpee" => 5.0
          }
        ]
      })

    assert {:ok, program} = PlanCompiler.compile(definition)

    assert [
             %ProgramEvent.Work{duration_sec: 16.0},
             %ProgramEvent.Rest{duration_sec: 10.0},
             %ProgramEvent.Work{duration_sec: 14.0}
           ] = program.events

    assert Program.duration_sec(program) == 40.0
    assert match?(%ProgramEvent.Work{}, List.last(program.events))
  end

  defp definition!(overrides) do
    attrs =
      Map.merge(
        %{
          "version" => 1,
          "name" => "Terminal active",
          "burpee_type" => "six_count",
          "target_reps" => 2,
          "target_duration_sec" => 20,
          "pacing_style" => "even",
          "rationale" => "Canonical compiler test.",
          "events" => [
            %{
              "kind" => "work",
              "reps" => 2,
              "sec_per_rep" => 15.0,
              "sec_per_burpee" => 5.0
            }
          ]
        },
        overrides
      )

    {:ok, definition} = WorkoutDefinition.new(attrs)
    definition
  end
end
