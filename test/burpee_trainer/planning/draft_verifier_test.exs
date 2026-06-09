defmodule BurpeeTrainer.Planning.DraftVerifierTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.{Draft, DraftGenerator, DraftVerifier, Goal}
  alias BurpeeTrainer.Planning.TimelineItem

  test "accepts an even draft within duration and rep tolerance" do
    {:ok,
     goal = %Goal{
       duration_sec: 1200,
       target_reps: 150,
       burpee_type: :six_count,
       style: :even
     }}

    {:ok, draft} = DraftGenerator.generate(goal)

    assert :ok = DraftVerifier.verify(draft)
  end

  test "rejects a giant even unit" do
    {:ok,
     goal = %Goal{
       duration_sec: 1200,
       target_reps: 150,
       burpee_type: :six_count,
       style: :even
     }}

    draft = %Draft{
      goal: goal,
      status: :good,
      timeline: [
        %TimelineItem.EvenUnit{
          id: "bad",
          start_sec: 0,
          duration_sec: 1200,
          reps: 150,
          rep_interval_sec: 8.0,
          burpee_duration_sec: 3.0
        }
      ],
      metadata: %{}
    }

    assert {:error, errors} = DraftVerifier.verify(draft)
    assert {:timeline, :giant_even_unit} in errors
  end

  test "rejects unbroken sets above max reps per set" do
    {:ok,
     goal = %Goal{
       duration_sec: 1200,
       target_reps: 160,
       burpee_type: :six_count,
       style: :unbroken,
       max_reps_per_set: 8
     }}

    draft = %Draft{
      goal: goal,
      status: :good,
      timeline: [
        %TimelineItem.UnbrokenGroup{
          id: "bad",
          start_sec: 0,
          reps: 12,
          burpee_duration_sec: 3.0,
          rest_after_sec: 30
        }
      ],
      metadata: %{}
    }

    assert {:error, errors} = DraftVerifier.verify(draft)
    assert {:unbroken_group, :exceeds_max_reps_per_set} in errors
  end
end
