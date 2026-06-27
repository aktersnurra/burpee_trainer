defmodule BurpeeTrainerWeb.PlansLive.Edit.PresentationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
  alias BurpeeTrainerWeb.PlansLive.Edit.Presentation

  defp set(position, reps, sec_per_rep, rest) do
    %Set{
      position: position,
      burpee_count: reps,
      sec_per_rep: sec_per_rep,
      sec_per_burpee: sec_per_rep,
      end_of_set_rest: rest
    }
  end

  defp plan do
    %WorkoutPlan{
      name: "Contract plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 45,
      pacing_style: :unbroken,
      blocks: [
        %Block{position: 1, repeat_count: 3, sets: [set(1, 15, 3.8, 38)]}
      ]
    }
  end

  test "contract summarizes duration, type, reps, blocks, and feel" do
    contract = Presentation.contract(plan(), %{duration_sec: 1_200, burpee_count: 45})

    assert contract.title == "20 min Six-count"
    assert contract.stats == "45 reps · 3 blocks"
    assert contract.structure == "Mostly unbroken, rests increase gradually"
    assert contract.feel == "Expected feel: controlled, not all-out"
  end

  test "block rows expand repeated blocks into readable rows" do
    rows = Presentation.block_rows(plan())

    assert length(rows) == 3
    assert Enum.at(rows, 0).title == "Block 1"
    assert Enum.at(rows, 0).headline == "Unbroken · 15 reps"
    assert Enum.at(rows, 0).detail == "Rep every 3.8s · 0:38 rest"
    assert Enum.at(rows, 2).title == "Block 3"
  end

  test "locked indexes are exposed as Locked by you" do
    [first | _] = Presentation.block_rows(plan(), MapSet.new([0]))

    assert first.locked? == true
    assert first.lock_label == "Locked by you"
  end

  test "structure map marks expose height, gap, and label" do
    rows = Presentation.block_rows(plan())
    marks = Presentation.structure_map(rows)

    assert length(marks) == 3
    assert hd(marks).label == "Block 1 · 15 reps"
    assert is_integer(hd(marks).height)
    assert is_integer(hd(marks).gap)
  end

  test "structure groups compact adjacent similar block rows" do
    rows = Presentation.block_rows(plan())

    assert [%{range: "1–3", label: "15 reps · 0:38 rest"}] =
             Presentation.structure_groups(rows)
  end
end
