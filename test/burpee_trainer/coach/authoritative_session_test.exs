defmodule BurpeeTrainer.Coach.AuthoritativeSessionTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.AuthoritativeSession

  @completed_at ~U[2026-08-27 10:00:00Z]
  @base %{
    id: 10,
    state: :completed,
    completed_at: @completed_at,
    burpee_type: :six_count,
    burpee_count_actual: 20,
    duration_sec_actual: 600,
    tags: nil
  }

  test "accepts completed immutable plan, video, and manual facts" do
    plan =
      Map.merge(@base, %{
        source_kind: :plan,
        plan_id: 1,
        workout_video_id: nil,
        display_name_snapshot: "Intervals",
        program_snapshot: %{"events" => []}
      })

    video =
      Map.merge(@base, %{
        source_kind: :video,
        plan_id: nil,
        workout_video_id: 2,
        display_name_snapshot: "Follow along",
        video_snapshot: %{"name" => "Follow along"}
      })

    manual =
      Map.merge(@base, %{
        source_kind: :manual,
        plan_id: nil,
        workout_video_id: nil,
        program_snapshot: nil,
        video_snapshot: nil
      })

    assert AuthoritativeSession.confirmed_non_warmup?(plan)
    assert AuthoritativeSession.confirmed_non_warmup?(video)
    assert AuthoritativeSession.confirmed_non_warmup?(manual)
  end

  test "retains a completed plan tombstone from its immutable snapshot" do
    tombstone =
      Map.merge(@base, %{
        source_kind: :plan,
        plan_id: nil,
        workout_video_id: nil,
        display_name_snapshot: "Archived workout",
        program_snapshot: %{"events" => [%{"kind" => "work", "reps" => 20}]}
      })

    assert AuthoritativeSession.authoritative?(tombstone)
  end

  test "rejects started, malformed, warmup, and non-positive facts" do
    completed_manual =
      Map.merge(@base, %{
        source_kind: :manual,
        plan_id: nil,
        workout_video_id: nil,
        program_snapshot: nil,
        video_snapshot: nil
      })

    refute AuthoritativeSession.authoritative?(%{completed_manual | state: :started})
    refute AuthoritativeSession.authoritative?(%{completed_manual | completed_at: nil})
    refute AuthoritativeSession.confirmed_non_warmup?(%{completed_manual | tags: "warmup"})

    refute AuthoritativeSession.confirmed_non_warmup?(%{
             completed_manual
             | burpee_count_actual: 0
           })
  end

  test "PB eligibility requires a prescribed 20-minute plan snapshot" do
    plan =
      Map.merge(@base, %{
        source_kind: :plan,
        plan_id: 1,
        workout_video_id: nil,
        display_name_snapshot: "Twenty minutes",
        program_snapshot: %{"events" => []},
        duration_sec_planned: 1_200
      })

    assert AuthoritativeSession.prescribed_plan_pb_eligible?(plan)
    refute AuthoritativeSession.prescribed_plan_pb_eligible?(%{plan | source_kind: :video})
    refute AuthoritativeSession.prescribed_plan_pb_eligible?(%{plan | duration_sec_planned: 600})
  end
end
