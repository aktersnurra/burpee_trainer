defmodule BurpeeTrainer.PlanCompiler.ProgramEventTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.ProgramEvent

  test "work events preserve distinct active duration and cadence" do
    event = ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0, sec_per_burpee: 5.0})

    assert Map.from_struct(event) == %{
             kind: :work,
             reps: 10,
             sec_per_rep: 12.0,
             sec_per_burpee: 5.0
           }
  end

  test "work events reject legacy and presentation fields" do
    assert_raise ArgumentError, ~r/unknown work event fields: \[:label, :set_index\]/, fn ->
      ProgramEvent.work!(%{
        reps: 10,
        sec_per_rep: 12.0,
        sec_per_burpee: 5.0,
        set_index: 1,
        label: "Set 1"
      })
    end
  end

  test "rest events reject identity and provenance fields" do
    assert_raise ArgumentError, ~r/unknown rest event fields: \[:id, :source\]/, fn ->
      ProgramEvent.rest!(%{duration_sec: 30, id: "rest-001", source: :explicit_rest})
    end
  end
end
