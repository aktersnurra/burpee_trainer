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
              ProgramEvent.work!(%{
                id: "work-001",
                set_index: 1,
                block_index: 1,
                reps: 10,
                duration_sec: 120.0,
                sec_per_rep: 12.0,
                label: "Set 1"
              })
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

  test "hash ignores display label changes" do
    changed_label =
      program(%{
        events: [
          ProgramEvent.work!(%{
            id: "work-001",
            set_index: 1,
            block_index: 1,
            reps: 10,
            duration_sec: 120.0,
            sec_per_rep: 12.0,
            label: "A prettier label"
          })
        ]
      })

    assert ProgramHash.hash(program()) == ProgramHash.hash(changed_label)
  end

  test "hash changes when executable cadence changes" do
    changed_cadence =
      program(%{
        target_duration_sec: 130,
        events: [
          ProgramEvent.work!(%{
            id: "work-001",
            set_index: 1,
            block_index: 1,
            reps: 10,
            duration_sec: 130.0,
            sec_per_rep: 13.0,
            label: "Set 1"
          })
        ]
      })

    refute ProgramHash.hash(program()) == ProgramHash.hash(changed_cadence)
  end
end
