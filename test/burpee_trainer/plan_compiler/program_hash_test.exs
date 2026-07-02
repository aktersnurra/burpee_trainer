defmodule BurpeeTrainer.PlanCompiler.ProgramHashTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent, ProgramHash}

  defp program(attrs \\ %{}) do
    {:ok, program} =
      Program.new(
        Map.merge(
          %{
            schema_version: 1,
            solver_version: 4,
            burpee_type: :six_count,
            target_reps: 10,
            target_duration_sec: 120,
            events: [
              ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0}),
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

  test "canonical map stores only executable event fields" do
    [work, rest] = ProgramHash.canonical_map(program()).events

    assert work == %{kind: "work", reps: 10, sec_per_rep_us: 12_000_000}
    assert rest == %{kind: "rest", duration_ms: 0}
  end

  test "hash changes when executable cadence changes" do
    changed_cadence =
      program(%{
        target_duration_sec: 130,
        events: [
          ProgramEvent.work!(%{reps: 10, sec_per_rep: 13.0}),
          ProgramEvent.rest!(%{duration_sec: 0.0})
        ]
      })

    refute ProgramHash.hash(program()) == ProgramHash.hash(changed_cadence)
  end
end
