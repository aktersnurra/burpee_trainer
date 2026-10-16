defmodule BurpeeTrainer.PlanCompiler.ProgramHashTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler

  alias BurpeeTrainer.PlanCompiler.{
    CompileError,
    Program,
    ProgramEvent,
    ProgramHash,
    ProgramValidator,
    WorkoutDefinition
  }

  alias BurpeeTrainer.TestFixtures.DeletionFirstFallback
  alias BurpeeTrainer.Workouts.Error

  defp program(attrs \\ %{}) do
    {:ok, program} =
      Program.new(
        Map.merge(
          %{
            schema_version: 2,
            solver_version: 4,
            burpee_type: :six_count,
            target_reps: 10,
            target_duration_sec: 120,
            events: [
              ProgramEvent.work!(%{
                reps: 10,
                sec_per_rep: 12.0,
                sec_per_burpee: 5.0
              }),
              ProgramEvent.rest!(%{duration_sec: 0.0})
            ],
            metadata: %{pacing_style: :even, recovery_model: :saved_up_rest}
          },
          attrs
        )
      )

    program
  end

  test "hash is stable for identical semantic programs" do
    assert ProgramHash.hash(program()) == ProgramHash.hash(program())
  end

  test "hash_canonical_map/1 matches hash/1 for canonical maps with atom or string keys" do
    canonical_map = ProgramHash.canonical_map(program())
    persisted_map = Jason.decode!(Jason.encode!(canonical_map))
    expected_hash = ProgramHash.hash(program())

    assert ProgramHash.hash_canonical_map(canonical_map) == expected_hash
    assert ProgramHash.hash_canonical_map(persisted_map) == expected_hash
  end

  test "canonical map stores only executable event fields" do
    [work, rest] = ProgramHash.canonical_map(program())["events"]

    assert work == %{
             "kind" => "work",
             "reps" => 10,
             "sec_per_rep_us" => 12_000_000,
             "sec_per_burpee_us" => 5_000_000
           }

    assert rest == %{"kind" => "rest", "duration_ms" => 0}
  end

  test "legacy encoding is deterministic and preserves the established fixture" do
    legacy_program = program(%{metadata: %{source: :plan_compiler}})

    assert ProgramHash.encode!(legacy_program) ==
             "{\"burpee_type\":\"six_count\",\"events\":[{\"kind\":\"work\",\"reps\":10,\"sec_per_burpee_us\":5000000,\"sec_per_rep_us\":12000000},{\"duration_ms\":0,\"kind\":\"rest\"}],\"schema_version\":2,\"semantics\":{},\"solver_version\":4,\"target_duration_ms\":120000,\"target_reps\":10}"

    assert ProgramHash.hash(legacy_program) ==
             "f7697792e4d8cd9a3091f14d23ffa04f32ebaf73ec2848eef3af25ab890d5296"
  end

  test "source v2 hashes include source provenance and ignore duration facts" do
    source_v2_program =
      program(%{
        metadata: %{
          source_version: 2,
          source_hash: "source-a",
          pacing_style: :even,
          recovery_model: :humane_even_v1,
          policy_version: 1,
          policy_hash: "policy-a",
          expected_duration_sec: 120.0,
          fast_bound_duration_sec: 115.0,
          slow_bound_duration_sec: 125.0,
          ignored: true
        }
      })

    changed_duration_facts =
      program(%{
        metadata: %{
          source_version: 2,
          source_hash: "source-a",
          pacing_style: :even,
          recovery_model: :humane_even_v1,
          policy_version: 1,
          policy_hash: "policy-a",
          expected_duration_sec: 999.0,
          fast_bound_duration_sec: 900.0,
          slow_bound_duration_sec: 1_100.0,
          ignored: false
        }
      })

    changed_source_hash =
      program(%{
        metadata: %{
          source_version: 2,
          source_hash: "source-b",
          pacing_style: :even,
          recovery_model: :humane_even_v1,
          policy_version: 1,
          policy_hash: "policy-a"
        }
      })

    assert ProgramHash.canonical_map(source_v2_program)["semantics"] == %{
             "pacing_style" => "even",
             "policy_hash" => "policy-a",
             "policy_version" => 1,
             "recovery_model" => "humane_even_v1",
             "source_hash" => "source-a",
             "source_version" => 2
           }

    assert ProgramHash.hash(source_v2_program) == ProgramHash.hash(changed_duration_facts)
    refute ProgramHash.hash(source_v2_program) == ProgramHash.hash(changed_source_hash)
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

  test "canonical map, encoding, and hash match the frozen fallback program" do
    assert {:ok, definition} = WorkoutDefinition.new(DeletionFirstFallback.definition_json())
    assert {:ok, program} = PlanCompiler.compile(definition)

    assert ProgramHash.canonical_map(program) == DeletionFirstFallback.program_json()
    assert Jason.decode!(ProgramHash.encode!(program)) == DeletionFirstFallback.program_json()
    assert ProgramHash.hash(program) == DeletionFirstFallback.content_hash()
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

    assert {:ok, %{"count" => nil} = snapshot, hash} = ProgramHash.video_snapshot(attrs)
    assert hash == "2928975fef50435bb32b5674e482af2afd1529308490c1f386d84c419f1c6c9e"
    assert ProgramHash.hash_canonical_map(snapshot) == hash
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

  test "hash changes when executable cadence changes" do
    changed_cadence =
      program(%{
        target_duration_sec: 130,
        events: [
          ProgramEvent.work!(%{
            reps: 10,
            sec_per_rep: 13.0,
            sec_per_burpee: 5.0
          }),
          ProgramEvent.rest!(%{duration_sec: 0.0})
        ]
      })

    refute ProgramHash.hash(program()) == ProgramHash.hash(changed_cadence)
  end
end
