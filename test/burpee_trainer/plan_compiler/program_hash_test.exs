defmodule BurpeeTrainer.PlanCompiler.ProgramHashTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.{
    CompileError,
    Program,
    ProgramEvent,
    ProgramHash,
    ProgramValidator
  }

  alias BurpeeTrainer.TestFixtures.DeletionFirstFallback
  alias BurpeeTrainer.Workouts.Error

  defp program(attrs \\ %{}) do
    {:ok, program} =
      Program.new(
        Map.merge(
          %{
            schema_version: 3,
            solver_version: 1,
            burpee_type: :six_count,
            target_reps: 10,
            target_duration_sec: 120,
            events: [ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0, sec_per_burpee: 5.0})],
            metadata: %{
              definition_hash: DeletionFirstFallback.definition_hash(),
              pacing_style: :even
            }
          },
          attrs
        )
      )

    program
  end

  test "hash is stable for identical programs and changes with executable cadence" do
    changed_cadence =
      program(%{
        target_duration_sec: 130,
        events: [ProgramEvent.work!(%{reps: 10, sec_per_rep: 13.0, sec_per_burpee: 5.0})]
      })

    assert ProgramHash.hash(program()) == ProgramHash.hash(program())
    refute ProgramHash.hash(program()) == ProgramHash.hash(changed_cadence)
  end

  test "canonical programs reject unknown top-level and semantic fields" do
    attrs = %{
      schema_version: 3,
      solver_version: 1,
      burpee_type: :six_count,
      target_reps: 10,
      target_duration_sec: 120,
      events: [
        ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0, sec_per_burpee: 5.0})
      ],
      metadata: %{definition_hash: DeletionFirstFallback.definition_hash(), pacing_style: :even}
    }

    assert {:error, %CompileError{code: :invalid_program}} =
             attrs
             |> Map.put(:unknown, true)
             |> Program.new()

    assert {:error, %CompileError{code: :invalid_program}} =
             attrs
             |> put_in([:metadata, :unknown], true)
             |> Program.new()
  end

  test "canonical program validator requires the frozen schema, solver, and semantic values" do
    base = %{
      schema_version: 3,
      solver_version: 1,
      burpee_type: :six_count,
      target_reps: 10,
      target_duration_sec: 120,
      events: [
        ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0, sec_per_burpee: 5.0})
      ],
      metadata: %{definition_hash: DeletionFirstFallback.definition_hash(), pacing_style: :even}
    }

    for attrs <- [
          Map.put(base, :solver_version, 2),
          put_in(base, [:metadata, :definition_hash], "not-a-hash"),
          put_in(base, [:metadata, :pacing_style], :unknown)
        ] do
      assert {:ok, program} = Program.new(attrs)
      assert {:error, %CompileError{code: :invalid_program}} = ProgramValidator.validate(program)
    end
  end

  test "video snapshot normalizes exact fields and hashes positive count stably" do
    attrs = %{
      name: "Steady 10",
      filename: "steady-10.mp4",
      type: :six_count,
      duration: 120,
      count: 10,
      format: :follow_along
    }

    assert {:ok, snapshot, hash} = ProgramHash.video_snapshot(attrs)

    assert snapshot == %{
             "name" => "Steady 10",
             "filename" => "steady-10.mp4",
             "type" => "six_count",
             "duration" => 120,
             "count" => 10,
             "format" => "follow_along"
           }

    assert hash == "86960048d7359e2fbe8b6ad1154b308447ddb3715725722fda72fd00c19b4235"
    assert ProgramHash.video_snapshot(snapshot) == {:ok, snapshot, hash}
  end

  test "video snapshot preserves nullable count and hashes it as JSON null" do
    attrs = %{
      "name" => "Steady",
      "filename" => "steady.mp4",
      "type" => "six_count",
      "duration" => 120,
      "count" => nil,
      "format" => "follow_along"
    }

    assert {:ok, %{"count" => nil}, hash} = ProgramHash.video_snapshot(attrs)
    assert hash == "2928975fef50435bb32b5674e482af2afd1529308490c1f386d84c419f1c6c9e"
  end

  test "video snapshot rejects unknown fields, invalid enums, and invalid measures" do
    valid = %{
      name: "Steady",
      filename: "steady.mp4",
      type: :six_count,
      duration: 120,
      count: nil,
      format: :follow_along
    }

    for attrs <- [
          Map.put(valid, :unknown, true),
          Map.put(valid, :type, :unknown),
          Map.put(valid, :format, :unknown),
          Map.put(valid, :duration, 0),
          Map.put(valid, :duration, 120.0),
          Map.put(valid, :count, 0),
          Map.put(valid, :count, 10.0)
        ] do
      assert {:error, %Error{code: :invalid_video_snapshot}} =
               ProgramHash.video_snapshot(attrs)
    end
  end
end
