defmodule BurpeeTrainer.Coach.RecommendationTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.{Policy, Recommendation}
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutSession}

  test "parses exactly select_existing and create provider actions" do
    assert {:ok, {:select_existing, 42, "Use the proven workout"}} =
             Recommendation.parse_proposal(%{
               "action" => "select_existing",
               "workout_plan_id" => 42,
               "rationale" => "Use the proven workout"
             })

    definition = definition("Coach option")

    assert {:ok, {:create, ^definition, "Try a measured option"}} =
             Recommendation.parse_proposal(%{
               "action" => "create",
               "definition" => definition,
               "rationale" => "Try a measured option"
             })
  end

  test "rejects provider video and unknown actions with no persistence" do
    user = user_fixture()
    before_count = Repo.aggregate(BurpeeTrainer.Workouts.WorkoutPlan, :count)

    for proposal <- [
          %{"action" => "select_video", "workout_video_id" => 1},
          %{"action" => "something_else"},
          %{"action" => "create", "definition" => %{}}
        ] do
      assert {:error, error} = Recommendation.apply_proposal(user, 999, proposal)
      assert error.code == :invalid_provider_response
    end

    assert Repo.aggregate(BurpeeTrainer.Workouts.WorkoutPlan, :count) == before_count
  end

  test "ensure recommendation is unique by user and slot and starts on built-in fallback" do
    user = user_fixture()
    attrs = %{slot_key: "2025-09-01:standard", slot_date: ~D[2025-09-01], rationale: "Fallback"}

    assert {:ok, first} = Workouts.ensure_recommendation(user, attrs)
    assert {:ok, second} = Workouts.ensure_recommendation(user, attrs)
    assert first.id == second.id
    assert first.selected_workout_plan_id
    assert is_nil(first.selected_workout_video_id)

    fallback = Repo.get!(BurpeeTrainer.Workouts.WorkoutPlan, first.selected_workout_plan_id)
    assert fallback.origin == :built_in
    assert fallback.state == :published

    assert Repo.aggregate(
             from(r in CoachRecommendation,
               where: r.user_id == ^user.id and r.slot_key == "2025-09-01:standard"
             ),
             :count
           ) == 1
  end

  test "select_existing applies an owned or shared published plan immediately" do
    user = user_fixture()
    plan = plan_fixture(user, %{name: "Owned option"})
    {:ok, recommendation} = ensure(user)

    assert {:ok, updated} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => plan.id,
               "rationale" => "Best fit"
             })

    assert updated.selected_workout_plan_id == plan.id
    assert is_nil(updated.selected_workout_video_id)
    assert updated.rationale == "Best fit"
  end

  test "create proposal attaches a verified coach draft and persists its rationale" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)

    assert {:ok, updated} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "create",
               "definition" => definition("Coach candidate"),
               "rationale" => "One measured change"
             })

    assert updated.rationale == "One measured change"
    assert updated.pending_draft_id
    assert Repo.get!(BurpeeTrainer.Workouts.WorkoutPlan, updated.pending_draft_id).state == :draft
  end

  test "rejects compiled proposals that violate the current deterministic slot" do
    user = user_fixture()
    wrong_type = plan_fixture(user, %{burpee_type: "navy_seal"})
    {:ok, recommendation} = ensure(user)

    assert {:error, selection_error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => wrong_type.id,
               "rationale" => "Wrong type"
             })

    assert selection_error.code == :invalid_recommendation_selection

    assert {:error, creation_error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "create",
               "definition" => definition("Too short", 120),
               "rationale" => "Wrong duration"
             })

    assert creation_error.code == :invalid_recommendation_selection
    assert is_nil(Repo.reload(recommendation).pending_draft_id)
  end

  test "provider select_existing rejects archived selections through the trusted library check" do
    user = user_fixture()
    plan = plan_fixture(user)
    {:ok, recommendation} = ensure(user)
    assert {:ok, _archived} = Workouts.archive_plan(user, plan.id)

    assert {:error, error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => plan.id,
               "rationale" => "Unavailable"
             })

    assert error.code == :invalid_recommendation_selection
    assert Repo.reload(recommendation).selected_workout_plan_id != plan.id
  end

  test "provider select_existing rejects more than one meaningful snapshot change" do
    user = user_fixture()
    baseline = plan_fixture(user, %{definition: structured_definition("Baseline", 100)})

    candidate =
      plan_fixture(user, %{definition: structured_definition("Candidate", 200, "unbroken")})

    complete_plan_snapshot(user, baseline, ~U[2025-08-31 09:00:00Z])
    {:ok, recommendation} = ensure(user)

    assert {:error, error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => candidate.id,
               "rationale" => "Too many changes"
             })

    assert error.code == :invalid_recommendation_selection
    assert Repo.reload(recommendation).selected_workout_plan_id != candidate.id
  end

  test "standard provider selection treats zero changes as reuse and allows exactly one measured change" do
    user = user_fixture()
    baseline = plan_fixture(user, %{definition: structured_definition("Baseline", 100)})
    same = plan_fixture(user, %{definition: structured_definition("Same structure", 100)})
    one_change = plan_fixture(user, %{definition: structured_definition("One change", 200)})
    complete_plan_snapshot(user, baseline, ~U[2025-08-31 09:00:00Z])
    {:ok, recommendation} = ensure(user)

    assert {:ok, reused} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => same.id,
               "rationale" => "No structural change"
             })

    assert reused.selected_workout_plan_id == same.id

    assert {:ok, explored} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => one_change.id,
               "rationale" => "One measured change"
             })

    assert explored.selected_workout_plan_id == one_change.id
  end

  test "persisted snapshot exploration frequency rejects provider create while manual facts stay in window" do
    user = user_fixture()
    baseline = plan_fixture(user, %{definition: structured_definition("Baseline", 100)})
    explored = plan_fixture(user, %{definition: structured_definition("Explored", 200)})

    complete_plan_snapshot(user, baseline, ~U[2025-08-28 09:00:00Z])
    complete_plan_snapshot(user, explored, ~U[2025-08-29 09:00:00Z])
    complete_manual(user, ~U[2025-08-30 09:00:00Z])
    {:ok, recommendation} = ensure(user)

    assert {:error, error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "create",
               "definition" => structured_definition("Next experiment", 200, "unbroken"),
               "rationale" => "Another measured change"
             })

    assert error.code == :invalid_recommendation_selection
    assert is_nil(Repo.reload(recommendation).pending_draft_id)
  end

  test "provider select and create both enforce weekend PB rep ceilings" do
    user = user_fixture()
    pb = plan_fixture(user, %{definition: catch_up_definition("PB", 1_200, 100)})
    complete_plan_snapshot(user, pb, ~U[2025-08-01 09:00:00Z])
    complete_manual(user, ~U[2025-09-01 09:00:00Z], 2_400, :navy_seal)
    above_ceiling = plan_fixture(user, %{definition: catch_up_definition("Above", 2_400, 151)})
    {:ok, recommendation} = ensure(user, ~D[2025-09-06])

    assert {:error, select_error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => above_ceiling.id,
               "rationale" => "Too many reps"
             })

    assert select_error.code == :invalid_recommendation_selection

    assert {:error, create_error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "create",
               "definition" => catch_up_definition("Generated above", 2_400, 151),
               "rationale" => "Still too many reps"
             })

    assert create_error.code == :invalid_recommendation_selection
    assert is_nil(Repo.reload(recommendation).pending_draft_id)
  end

  test "slot-day cutoff includes post-noon completions and rejects a stale built-in proposal" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    stale_fallback_id = recommendation.selected_workout_plan_id
    complete_manual(user, ~U[2025-09-01 13:00:00Z], 4_000)

    assert {:ok, slot} = Policy.required_slot_for_date(user, ~D[2025-09-01])
    assert slot.burpee_type == :navy_seal
    assert slot.duration_sec == 800

    assert {:error, error} =
             Recommendation.apply_proposal(user, recommendation.id, %{
               "action" => "select_existing",
               "workout_plan_id" => stale_fallback_id,
               "rationale" => "Stale before completion"
             })

    assert error.code == :invalid_recommendation_selection
  end

  test "provider selection revalidates current policy inside the expected-selection transaction" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    fallback_id = recommendation.selected_workout_plan_id
    expected_selection = {:plan, fallback_id}

    complete_manual(user, ~U[2025-09-01 13:00:00Z], 4_000)

    assert {:error, error} =
             Workouts.select_recommendation_candidate_if_current(
               user,
               recommendation.id,
               fallback_id,
               "Provider response became stale",
               expected_selection
             )

    assert error.code == :invalid_recommendation_selection
    persisted = Repo.reload(recommendation)
    assert persisted.selected_workout_plan_id == fallback_id
    assert persisted.rationale == recommendation.rationale
  end

  test "manual selection enforces exact plan/video exclusivity and availability" do
    user = user_fixture()
    other = user_fixture()
    own_plan = plan_fixture(user)
    foreign_plan = plan_fixture(other)
    own_draft = workout_plan_draft_fixture(user)
    video = video_fixture()
    unavailable_video = video_fixture(%{available: false})
    {:ok, recommendation} = ensure(user)

    assert {:ok, selected_video} =
             Workouts.select_recommendation(user, recommendation.id, {:video, video.id}, "Video")

    assert selected_video.selected_workout_video_id == video.id
    assert is_nil(selected_video.selected_workout_plan_id)

    assert {:ok, selected_plan} =
             Workouts.select_recommendation(user, recommendation.id, {:plan, own_plan.id}, "Plan")

    assert selected_plan.selected_workout_plan_id == own_plan.id
    assert is_nil(selected_plan.selected_workout_video_id)

    for selection <- [
          {:plan, own_draft.id},
          {:plan, foreign_plan.id},
          {:video, unavailable_video.id},
          {:video, -1},
          {:unknown, own_plan.id}
        ] do
      assert {:error, error} =
               Workouts.select_recommendation(user, recommendation.id, selection, "No")

      assert error.code == :invalid_recommendation_selection
    end
  end

  defp ensure(user, slot_date \\ ~D[2025-09-01]) do
    Workouts.ensure_recommendation(user, %{
      slot_key: "#{Date.to_iso8601(slot_date)}:#{System.unique_integer([:positive])}",
      slot_date: slot_date,
      rationale: "Fallback"
    })
  end

  defp complete_plan_snapshot(user, plan, completed_at) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :plan,
      display_name_snapshot: plan.name,
      program_snapshot: plan.program_json,
      content_hash: plan.content_hash,
      burpee_type: plan.burpee_type,
      burpee_count_actual: plan.target_reps,
      duration_sec_actual: plan.target_duration_sec,
      duration_sec_planned: plan.target_duration_sec,
      completed_at: completed_at,
      capture_mode: :logged
    }
    |> Repo.insert!()
  end

  defp complete_manual(user, completed_at, duration_sec \\ 300, burpee_type \\ :six_count) do
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

  defp catch_up_definition(name, duration_sec, reps) do
    total_us = duration_sec * 1_000_000
    base_us = div(total_us, reps)
    longer_reps = rem(total_us, reps)

    events =
      [{longer_reps, base_us + 1}, {reps - longer_reps, base_us}]
      |> Enum.flat_map(fn
        {0, _sec_per_rep_us} ->
          []

        {event_reps, sec_per_rep_us} ->
          sec_per_rep = sec_per_rep_us / 1_000_000

          [
            %{
              "kind" => "work",
              "reps" => event_reps,
              "sec_per_burpee" => sec_per_rep,
              "sec_per_rep" => sec_per_rep
            }
          ]
      end)

    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_duration_sec" => duration_sec,
      "target_reps" => reps,
      "pacing_style" => "even",
      "rationale" => "Catch-up",
      "events" => events
    }
  end

  defp definition(name, target_duration_sec \\ 1_200) do
    %{
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
  end
end
