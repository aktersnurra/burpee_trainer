defmodule BurpeeTrainer.Workouts.RecommendationLifecycleTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}

  test "generated candidate creation and attachment are atomic and leave a non-startable draft" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)

    assert {:ok, attached} =
             Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    draft = Repo.get!(WorkoutPlan, attached.pending_draft_id)
    assert draft.user_id == user.id
    assert draft.origin == :coach
    assert draft.state == :draft
    refute draft.origin == :built_in

    assert {:error, error} = Workouts.start_plan(user, draft.id, Ecto.UUID.generate())
    assert error.code == :draft_cannot_start

    assert {:error, duplicate_error} =
             Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Duplicate"))

    assert duplicate_error.code == :candidate_no_longer_current

    assert Repo.aggregate(
             from(p in WorkoutPlan,
               where: p.user_id == ^user.id and p.origin == :coach and p.state == :draft
             ),
             :count
           ) == 1
  end

  test "attachment rejects policy-mismatched definitions without leaving an orphan draft" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    before_count = Repo.aggregate(WorkoutPlan, :count)

    assert {:error, error} =
             Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Too short", 120))

    assert error.code == :invalid_recommendation_selection
    assert Repo.aggregate(WorkoutPlan, :count) == before_count
    assert is_nil(Repo.reload(recommendation).pending_draft_id)
  end

  test "direct attachment rejects more than one meaningful immutable-snapshot change without an orphan" do
    user = user_fixture()
    baseline = plan_fixture(user, %{definition: structured_definition("Baseline", 100)})
    complete_plan_snapshot(user, baseline, ~U[2025-08-31 09:00:00Z], 10)
    {:ok, recommendation} = ensure(user)
    before_count = Repo.aggregate(WorkoutPlan, :count)

    assert {:error, error} =
             Workouts.attach_candidate(
               user,
               recommendation.id,
               attrs_for_definition(structured_definition("Too broad", 200, "unbroken"))
             )

    assert error.code == :invalid_recommendation_selection
    assert Repo.aggregate(WorkoutPlan, :count) == before_count
    assert is_nil(Repo.reload(recommendation).pending_draft_id)
  end

  test "weekend catch-up requires exact duration and enforces 40/60/80 PB ceilings" do
    for {remaining_sec, expected_ceiling} <- [
          {2_400, 150},
          {3_000, 150},
          {3_600, 180},
          {4_800, 200}
        ] do
      user = user_fixture()
      pb_plan = plan_fixture(user, %{definition: definition_for("PB", 1_200, 100, "six_count")})
      complete_plan_snapshot(user, pb_plan, ~U[2025-08-01 09:00:00Z], 100)

      if remaining_sec < 4_800 do
        complete_manual(user, ~U[2025-09-01 09:00:00Z], 4_800 - remaining_sec, :navy_seal)
      end

      {:ok, recommendation} = ensure(user, ~D[2025-09-06])

      assert {:error, duration_error} =
               Workouts.attach_candidate(
                 user,
                 recommendation.id,
                 attrs_for_definition(
                   definition_for("Partial", remaining_sec - 60, expected_ceiling, "six_count")
                 )
               )

      assert duration_error.code == :invalid_recommendation_selection

      assert {:error, ceiling_error} =
               Workouts.attach_candidate(
                 user,
                 recommendation.id,
                 attrs_for_definition(
                   definition_for(
                     "Above ceiling",
                     remaining_sec,
                     expected_ceiling + 1,
                     "six_count"
                   )
                 )
               )

      assert ceiling_error.code == :invalid_recommendation_selection

      assert {:ok, attached} =
               Workouts.attach_candidate(
                 user,
                 recommendation.id,
                 attrs_for_definition(
                   definition_for("At ceiling", remaining_sec, expected_ceiling, "six_count")
                 )
               )

      assert Repo.get!(WorkoutPlan, attached.pending_draft_id).target_reps == expected_ceiling
    end
  end

  test "direct publish and delete of an attached candidate are blocked" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    assert {:error, publish_error} = Workouts.publish_draft(user, attached.pending_draft_id)
    assert publish_error.code == :candidate_attached

    assert {:error, delete_error} = Workouts.delete_draft(user, attached.pending_draft_id)
    assert delete_error.code == :candidate_attached
  end

  test "accept clears, reverifies, publishes, and selects in one immediate transaction" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    expected = {:plan, recommendation.selected_workout_plan_id}

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    draft_id = attached.pending_draft_id

    assert {:ok, accepted} =
             Workouts.accept_candidate(user, recommendation.id, draft_id, expected)

    assert is_nil(accepted.pending_draft_id)
    assert accepted.selected_workout_plan_id == draft_id
    assert is_nil(accepted.selected_workout_video_id)
    assert Repo.get!(WorkoutPlan, draft_id).state == :published
  end

  test "reject clears and hard-deletes in one transaction while retaining exact selection" do
    user = user_fixture()
    video = video_fixture()
    {:ok, recommendation} = ensure(user)

    {:ok, recommendation} =
      Workouts.select_recommendation(user, recommendation.id, {:video, video.id}, "Keep video")

    expected = {:video, video.id}

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    draft_id = attached.pending_draft_id

    assert {:ok, rejected} =
             Workouts.reject_candidate(user, recommendation.id, draft_id, expected)

    assert is_nil(rejected.pending_draft_id)
    assert rejected.selected_workout_video_id == video.id
    assert is_nil(rejected.selected_workout_plan_id)
    assert is_nil(Repo.get(WorkoutPlan, draft_id))
  end

  test "stale selection, stale draft identity, and duplicate decisions change nothing" do
    user = user_fixture()
    plan = plan_fixture(user)
    {:ok, recommendation} = ensure(user)
    original = {:plan, recommendation.selected_workout_plan_id}

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    draft_id = attached.pending_draft_id

    {:ok, changed} =
      Workouts.select_recommendation(user, recommendation.id, {:plan, plan.id}, "Changed")

    assert {:error, selection_error} =
             Workouts.accept_candidate(user, recommendation.id, draft_id, original)

    assert selection_error.code == :recommendation_selection_changed
    assert Repo.get!(WorkoutPlan, draft_id).state == :draft
    assert Repo.get!(CoachRecommendation, recommendation.id).pending_draft_id == draft_id

    assert {:error, identity_error} =
             Workouts.reject_candidate(user, recommendation.id, draft_id + 999, {:plan, plan.id})

    assert identity_error.code == :candidate_no_longer_current
    assert Repo.get!(CoachRecommendation, recommendation.id).pending_draft_id == draft_id

    assert {:ok, _rejected} =
             Workouts.reject_candidate(user, recommendation.id, draft_id, {:plan, plan.id})

    assert {:error, duplicate_error} =
             Workouts.reject_candidate(user, recommendation.id, draft_id, {:plan, plan.id})

    assert duplicate_error.code == :candidate_no_longer_current
    assert changed.selected_workout_plan_id == plan.id
  end

  test "failed stored-draft re-verification rolls back candidate detachment" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    expected = {:plan, recommendation.selected_workout_plan_id}

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    draft_id = attached.pending_draft_id

    Repo.update_all(from(p in WorkoutPlan, where: p.id == ^draft_id), set: [content_hash: "bad"])

    assert {:error, error} =
             Workouts.accept_candidate(user, recommendation.id, draft_id, expected)

    assert error.code == :infeasible_workout_definition
    assert Repo.get!(CoachRecommendation, recommendation.id).pending_draft_id == draft_id
    assert Repo.get!(WorkoutPlan, draft_id).state == :draft
  end

  test "availability check selects the fallback for invalid plan/video selections to fallback and preserves candidate" do
    user = user_fixture()
    archived = plan_fixture(user)
    unavailable = video_fixture(%{available: false})
    {:ok, recommendation} = ensure(user)

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Candidate"))

    pending_id = attached.pending_draft_id

    assert {:ok, _archived} = Workouts.archive_plan(user, archived.id)

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: archived.id, selected_workout_video_id: nil]
    )

    assert {:ok, available_plan} =
             Workouts.ensure_recommendation_selection_available(user, recommendation.id)

    assert available_plan.pending_draft_id == pending_id
    assert Repo.get!(WorkoutPlan, available_plan.selected_workout_plan_id).origin == :built_in

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: nil, selected_workout_video_id: unavailable.id]
    )

    assert {:ok, available_video} =
             Workouts.ensure_recommendation_selection_available(user, recommendation.id)

    assert available_video.pending_draft_id == pending_id
    assert Repo.get!(WorkoutPlan, available_video.selected_workout_plan_id).origin == :built_in
  end

  defp ensure(user, slot_date \\ ~D[2025-09-01]) do
    Workouts.ensure_recommendation(user, %{
      slot_key: "#{Date.to_iso8601(slot_date)}:#{System.unique_integer([:positive])}",
      slot_date: slot_date,
      rationale: "Fallback"
    })
  end

  defp complete_plan_snapshot(user, plan, completed_at, actual_reps) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :plan,
      display_name_snapshot: plan.name,
      program_snapshot: plan.program_json,
      content_hash: plan.content_hash,
      burpee_type: plan.burpee_type,
      burpee_count_actual: actual_reps,
      duration_sec_actual: plan.target_duration_sec,
      duration_sec_planned: plan.target_duration_sec,
      completed_at: completed_at,
      capture_mode: :logged
    }
    |> Repo.insert!()
  end

  defp complete_manual(user, completed_at, duration_sec, burpee_type) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      burpee_type: burpee_type,
      burpee_count_actual: 10,
      duration_sec_actual: duration_sec,
      completed_at: completed_at,
      capture_mode: :logged
    }
    |> Repo.insert!()
  end

  defp attrs_for_definition(definition) do
    %{request_text: "Make a focused workout", definition: definition}
  end

  defp structured_definition(name, recovery_sec, pacing_style \\ "even") do
    work_sec = div(1_200 - recovery_sec, 10)

    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_duration_sec" => 1_200,
      "target_reps" => 10,
      "pacing_style" => pacing_style,
      "rationale" => "Structured candidate",
      "events" => [
        %{
          "kind" => "work",
          "reps" => 5,
          "sec_per_burpee" => 5.0,
          "sec_per_rep" => work_sec * 1.0
        },
        %{"kind" => "rest", "duration_sec" => recovery_sec * 1.0},
        %{
          "kind" => "work",
          "reps" => 5,
          "sec_per_burpee" => work_sec * 1.0,
          "sec_per_rep" => work_sec * 1.0
        }
      ]
    }
  end

  defp definition_for(name, duration_sec, reps, burpee_type) do
    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => burpee_type,
      "target_duration_sec" => duration_sec,
      "target_reps" => reps,
      "pacing_style" => "even",
      "rationale" => "Catch-up",
      "events" => exact_work_events(duration_sec, reps)
    }
  end

  defp exact_work_events(duration_sec, reps) do
    total_us = duration_sec * 1_000_000
    base_us = div(total_us, reps)
    longer_reps = rem(total_us, reps)

    []
    |> maybe_add_work(longer_reps, base_us + 1)
    |> maybe_add_work(reps - longer_reps, base_us)
  end

  defp maybe_add_work(events, reps, sec_per_rep_us) when reps > 0 do
    sec_per_rep = sec_per_rep_us / 1_000_000

    events ++
      [
        %{
          "kind" => "work",
          "reps" => reps,
          "sec_per_burpee" => sec_per_rep,
          "sec_per_rep" => sec_per_rep
        }
      ]
  end

  defp maybe_add_work(events, _reps, _sec_per_rep_us), do: events

  defp candidate_attrs(name, target_duration_sec \\ 1_200) do
    %{
      request_text: "Make a focused workout",
      definition: %{
        "version" => 1,
        "name" => name,
        "burpee_type" => "six_count",
        "target_duration_sec" => target_duration_sec,
        "target_reps" => 10,
        "pacing_style" => "even",
        "rationale" => "Focused work",
        "events" => [
          %{
            "kind" => "work",
            "reps" => 10,
            "sec_per_burpee" => target_duration_sec / 10,
            "sec_per_rep" => target_duration_sec / 10
          }
        ]
      }
    }
  end
end
