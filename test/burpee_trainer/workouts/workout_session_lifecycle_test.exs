defmodule BurpeeTrainer.Workouts.WorkoutSessionLifecycleTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.PlanCompiler.ProgramHash
  alias BurpeeTrainer.{Goals, Repo, Workouts}

  alias BurpeeTrainer.Workouts.{
    CoachRecommendation,
    Error,
    PoseCaptureRun,
    SessionLog,
    WorkoutSession
  }

  describe "Start" do
    test "returns exact lifecycle and availability errors after a visibility lookup" do
      owner = user_fixture()
      other_user = user_fixture()
      draft = workout_plan_draft_fixture(owner, %{"name" => "Draft source"})
      archived = plan_fixture(owner, %{"name" => "Archived source"})
      foreign = plan_fixture(other_user, %{"name" => "Foreign source"})
      assert {:ok, archived} = Workouts.archive_plan(owner, archived.id)

      assert {:error, %Error{code: :draft_cannot_start, context: %{plan_id: draft_id}}} =
               Workouts.start_plan(owner, draft.id, Ecto.UUID.generate())

      assert draft_id == draft.id

      assert {:error, %Error{code: :archived_workout, context: %{plan_id: archived_id}}} =
               Workouts.start_plan(owner, archived.id, Ecto.UUID.generate())

      assert archived_id == archived.id

      for plan_id <- [foreign.id, 2_147_483_647] do
        assert {:error, %Error{code: :source_unavailable, context: %{plan_id: ^plan_id}}} =
                 Workouts.start_plan(owner, plan_id, Ecto.UUID.generate())
      end

      unavailable = video_fixture(%{available: false})

      for video_id <- [unavailable.id, 2_147_483_646] do
        assert {:error, %Error{code: :source_unavailable, context: %{video_id: ^video_id}}} =
                 Workouts.start_video(owner, video_id, Ecto.UUID.generate())
      end

      assert Repo.aggregate(WorkoutSession, :count) == 0
    end

    test "idempotency is exact user and client ID and precedes source lookup" do
      user = user_fixture()
      other_user = user_fixture()
      plan = plan_fixture(user)
      other_plan = plan_fixture(other_user)
      client_id = Ecto.UUID.generate()

      assert {:ok, first} = Workouts.start_plan(user, plan.id, client_id)

      assert {:ok, same} = Workouts.start_video(user, 2_147_483_647, client_id)
      assert same.id == first.id
      assert same.source_kind == :plan
      assert Repo.aggregate(WorkoutSession, :count) == 1

      assert {:ok, other_session} = Workouts.start_plan(other_user, other_plan.id, client_id)
      assert other_session.id != first.id

      assert {:ok, second} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
      assert second.id != first.id

      assert Repo.aggregate(
               from(session in WorkoutSession, where: session.user_id == ^user.id),
               :count
             ) == 2
    end

    test "published plan Start immediately persists the exact immutable execution snapshot" do
      user = user_fixture()
      plan = plan_fixture(user, %{"name" => "Snapshot plan", "burpee_type" => "navy_seal"})
      client_id = Ecto.UUID.generate()
      before_start = DateTime.utc_now(:second)

      assert {:ok, session} = Workouts.start_plan(user, plan.id, client_id)
      after_start = DateTime.utc_now(:second)

      assert session.state == :started
      assert session.source_kind == :plan
      assert session.user_id == user.id
      assert session.plan_id == plan.id
      assert session.workout_video_id == nil
      assert session.display_name_snapshot == plan.name
      assert session.workout_type_snapshot == plan.burpee_type
      assert session.burpee_type == plan.burpee_type
      assert session.burpee_count_planned == plan.target_reps
      assert session.duration_sec_planned == plan.target_duration_sec
      assert session.program_snapshot == plan.program_json
      assert session.video_snapshot == nil
      assert session.content_hash == plan.content_hash
      assert session.client_session_id == client_id
      assert DateTime.compare(session.started_at, before_start) in [:eq, :gt]
      assert DateTime.compare(session.started_at, after_start) in [:eq, :lt]
      assert session.completed_at == nil
      assert session.burpee_count_actual == nil
      assert session.duration_sec_actual == nil
      assert Repo.get!(WorkoutSession, session.id) == session
    end

    test "available video Start copies exactly six canonical fields for prescribed and nil counts" do
      user = user_fixture()

      for count <- [42, nil] do
        video =
          video_fixture(%{
            name: "Snapshot video #{inspect(count)}",
            filename: "snapshot-#{inspect(count)}-#{System.unique_integer([:positive])}.mp4",
            burpee_type: :six_count,
            duration_sec: 321,
            burpee_count: count,
            format: :follow_along,
            available: true
          })

        expected_snapshot = %{
          "name" => video.name,
          "filename" => video.filename,
          "type" => "six_count",
          "duration" => 321,
          "count" => count,
          "format" => "follow_along"
        }

        assert {:ok, ^expected_snapshot, expected_hash} =
                 ProgramHash.video_snapshot(expected_snapshot)

        assert {:ok, session} =
                 Workouts.start_video(user, video.id, Ecto.UUID.generate())

        assert session.state == :started
        assert session.source_kind == :video
        assert session.plan_id == nil
        assert session.workout_video_id == video.id
        assert session.display_name_snapshot == video.name
        assert session.workout_type_snapshot == :six_count
        assert session.burpee_type == :six_count
        assert session.burpee_count_planned == count
        assert session.duration_sec_planned == 321
        assert session.program_snapshot == nil
        assert session.video_snapshot == expected_snapshot
        assert session.content_hash == expected_hash
      end
    end
  end

  describe "Resume and completion" do
    test "Resume scopes exact user/session and uses the stored snapshot after archive and recommendation replacement" do
      user = user_fixture()
      intruder = user_fixture()
      plan = plan_fixture(user)

      fallback =
        Repo.one!(
          from(candidate in BurpeeTrainer.Workouts.WorkoutPlan,
            where: candidate.origin == :built_in and candidate.state == :published
          )
        )

      recommendation =
        %CoachRecommendation{
          user_id: user.id,
          slot_key: "resume-#{System.unique_integer([:positive])}",
          slot_date: Date.utc_today(),
          selected_workout_plan_id: plan.id
        }
        |> Repo.insert!()

      assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
      snapshot = started.program_snapshot
      assert {:ok, _archived} = Workouts.archive_plan(user, plan.id)
      assert Repo.reload(recommendation).selected_workout_plan_id == fallback.id

      assert {:ok, resumed} = Workouts.resume_session(user, started.id)
      assert resumed.id == started.id
      assert resumed.program_snapshot == snapshot
      assert resumed.state == :started

      assert {:error, %Error{code: :session_not_owned, context: %{session_id: session_id}}} =
               Workouts.resume_session(intruder, started.id)

      assert session_id == started.id

      assert {:error, %Error{code: :session_not_owned}} =
               Workouts.resume_session(user, 2_147_483_647)
    end

    test "completion updates the same row once and retains derived capture and typed feedback" do
      user = user_fixture()
      plan = plan_fixture(user)
      assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

      attrs = %{
        "burpee_count_actual" => 4,
        "duration_sec_actual" => 20,
        "note_post" => "Confirmed",
        "mood" => 1,
        "tags" => "great_energy",
        "context_low_energy" => false,
        "context_high_energy" => true,
        "context_heat_affected" => true,
        "primary_limiter" => "breathing",
        "preference_feedback" => "choose_again"
      }

      assert {:ok, completed} =
               Workouts.complete_session(
                 user,
                 started.id,
                 attrs,
                 {:trusted, [5_000, 10_000, 15_000, 20_000], 5.0}
               )

      assert completed.id == started.id
      assert completed.state == :completed
      assert completed.completed_at
      assert completed.capture_mode == :tracked
      assert completed.cadence_ms == "[5000,10000,15000,20000]"
      assert completed.target_pace_sec == 5.0
      assert completed.pace_consistency == 1.0
      assert completed.context_high_energy
      assert completed.context_heat_affected
      assert completed.primary_limiter == :breathing
      assert completed.preference_feedback == :choose_again
      assert completed.rate_per_min_actual == 12.0
      assert Repo.aggregate(WorkoutSession, :count) == 1

      assert {:error,
              %Error{code: :session_already_completed, context: %{session_id: session_id}}} =
               Workouts.complete_session(user, started.id, attrs, :timed)

      assert session_id == started.id
      assert Repo.aggregate(WorkoutSession, :count) == 1
      assert Repo.get!(WorkoutSession, started.id) == completed
    end

    test "nil-count videos preserve confirmed actual reps at completion" do
      user = user_fixture()
      video = video_fixture(%{burpee_count: nil})
      assert {:ok, started} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
      assert started.burpee_count_planned == nil

      assert {:ok, completed} =
               Workouts.complete_session(
                 user,
                 started.id,
                 %{"burpee_count_actual" => 37, "duration_sec_actual" => 600},
                 :logged
               )

      assert completed.id == started.id
      assert completed.burpee_count_planned == nil
      assert completed.burpee_count_actual == 37
    end

    test "failed goal-achieving completion rolls back both session attribution and goal state" do
      user = user_fixture()
      plan = plan_fixture(user)

      goal =
        goal_fixture(user, %{
          "burpee_count_target" => 10,
          "burpee_count_baseline" => 5
        })

      assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

      assert {:error, %Ecto.Changeset{}} =
               Workouts.complete_session(
                 user,
                 started.id,
                 %{
                   "burpee_count_actual" => 10,
                   "duration_sec_actual" => 1200,
                   "context_low_energy" => true,
                   "context_high_energy" => true
                 },
                 :timed
               )

      unchanged = Repo.get!(WorkoutSession, started.id)
      assert unchanged.state == :started
      assert unchanged.goal_id == nil
      assert Goals.get_goal!(user, goal.id).status == :active
    end

    test "completion rejects foreign and missing sessions without inserting" do
      owner = user_fixture()
      intruder = user_fixture()
      plan = plan_fixture(owner)
      assert {:ok, started} = Workouts.start_plan(owner, plan.id, Ecto.UUID.generate())
      attrs = %{"burpee_count_actual" => 1, "duration_sec_actual" => 1}

      for id <- [started.id, 2_147_483_647] do
        assert {:error, %Error{code: :session_not_owned}} =
                 Workouts.complete_session(intruder, id, attrs, :timed)
      end

      assert Repo.get!(WorkoutSession, started.id).state == :started
    end
  end

  describe "manual history and pose evidence" do
    test "free-form logging inserts completed/manual with the validated historical time" do
      user = user_fixture()
      completed_at = ~U[2025-02-03 12:34:56Z]

      assert {:ok, session} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "navy_seal",
                 "burpee_count_actual" => 25,
                 "duration_sec_actual" => 400,
                 "completed_at" => DateTime.to_iso8601(completed_at)
               })

      assert session.state == :completed
      assert session.source_kind == :manual
      assert session.started_at == nil
      assert session.completed_at == completed_at
      assert session.plan_id == nil
      assert session.workout_video_id == nil
      assert session.program_snapshot == nil
      assert session.video_snapshot == nil
      assert session.client_session_id == nil

      assert {:error, changeset} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => 10,
                 "duration_sec_actual" => 100,
                 "completed_at" =>
                   DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601()
               })

      assert "cannot be in the future" in errors_on(changeset).completed_at

      for completed_at <- [nil, "not-a-date-time"] do
        assert {:error, invalid_changeset} =
                 Workouts.create_free_form_session(user, %{
                   "burpee_type" => "six_count",
                   "burpee_count_actual" => 10,
                   "duration_sec_actual" => 100,
                   "completed_at" => completed_at
                 })

        assert errors_on(invalid_changeset).completed_at != []
      end
    end

    test "new pose runs are bound to an already-created owned session" do
      user = user_fixture()
      intruder = user_fixture()
      plan = plan_fixture(user)
      assert {:ok, session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

      assert {:ok, %PoseCaptureRun{} = run} = Workouts.start_pose_capture_run(user, session)
      assert run.user_id == user.id
      assert run.workout_session_id == session.id
      assert run.status == :active

      assert {:error, :not_found} = Workouts.start_pose_capture_run(intruder, session)
    end

    test "pose completion rejects forged cross-owner and same-owner session relinking" do
      owner = user_fixture()
      other_user = user_fixture()
      owner_plan = plan_fixture(owner)
      other_plan = plan_fixture(other_user)

      assert {:ok, bound_session} =
               Workouts.start_plan(owner, owner_plan.id, Ecto.UUID.generate())

      assert {:ok, other_owner_session} =
               Workouts.start_plan(other_user, other_plan.id, Ecto.UUID.generate())

      assert {:ok, same_owner_mismatch} =
               Workouts.start_plan(owner, owner_plan.id, Ecto.UUID.generate())

      assert {:ok, run} = Workouts.start_pose_capture_run(owner, bound_session)

      forged = %WorkoutSession{id: other_owner_session.id, user_id: owner.id}

      for mismatched_session <- [forged, same_owner_mismatch] do
        assert {:error, :not_found} =
                 Workouts.complete_pose_capture_run(owner, run, mismatched_session)

        unchanged = Repo.get!(PoseCaptureRun, run.id)
        assert unchanged.status == :active
        assert unchanged.workout_session_id == bound_session.id
        assert unchanged.completed_at == nil
      end
    end

    test "free-form date parsing rejects empty, malformed, and future local dates and accepts user today" do
      user = %User{timezone: "Pacific/Kiritimati"}
      now = ~U[2025-02-03 23:30:00Z]
      local_today = "2025-02-04"
      base = %{"burpee_count_actual" => "10", "duration_sec_actual" => "2"}

      for invalid <- [
            nil,
            "",
            "not-a-date",
            123,
            1.5,
            %{},
            [],
            true,
            {:forged, :date}
          ] do
        params = Map.put(base, "log_date", invalid)
        assert {:error, :invalid_log_date} = SessionLog.parse_log_date(params)

        assert {:error, _reason} =
                 SessionLog.to_attrs(
                   params,
                   :six_count,
                   0,
                   [],
                   user,
                   now
                 )
      end

      assert {:error, :future_log_date} =
               SessionLog.to_attrs(
                 Map.put(base, "log_date", "2025-02-05"),
                 :six_count,
                 0,
                 [],
                 user,
                 now
               )

      assert {:ok, attrs} =
               SessionLog.to_attrs(
                 Map.put(base, "log_date", local_today),
                 :six_count,
                 0,
                 [],
                 user,
                 now
               )

      assert attrs["completed_at"] == now
    end

    test "free-form duration normalizes forged values into ordinary changeset errors" do
      user = user_fixture()
      now = DateTime.utc_now(:second)
      date = Date.to_iso8601(Date.utc_today())

      for forged <- [123, %{}, [], true] do
        assert {:ok, attrs} =
                 SessionLog.to_attrs(
                   %{
                     "burpee_count_actual" => "10",
                     "duration_sec_actual" => forged,
                     "log_date" => date
                   },
                   :six_count,
                   0,
                   [],
                   user,
                   now
                 )

        assert attrs["duration_sec_actual"] == ""

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Workouts.create_free_form_session(user, attrs)

        assert "can't be blank" in errors_on(changeset).duration_sec_actual
      end

      assert {:ok, attrs} =
               SessionLog.to_attrs(
                 %{
                   "burpee_count_actual" => "10",
                   "duration_sec_actual" => "2",
                   "log_date" => date
                 },
                 :six_count,
                 0,
                 [],
                 user,
                 now
               )

      assert attrs["duration_sec_actual"] == "120"
    end

    test "user-local midnight drives derived day, time bucket, and week milestones" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(timezone: "America/Los_Angeles")
        |> Repo.update!()

      assert {:ok, prior} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => 100,
                 "duration_sec_actual" => 600,
                 "completed_at" => "2025-02-10T07:30:00Z"
               })

      assert prior.time_of_day_bucket == "night"

      assert {:ok, after_midnight} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => 1,
                 "duration_sec_actual" => 60,
                 "completed_at" => "2025-02-10T08:30:00Z"
               })

      assert after_midnight.days_since_last == 1
      assert after_midnight.time_of_day_bucket == "night"
      assert Workouts.current_week_pushups(user, ~D[2025-02-10]) == 1

      events = Workouts.session_milestones(user, after_midnight)
      refute Enum.any?(events, &(&1.type == :week_pushup_pr))
    end

    test "backdated insertion excludes later sessions from chronology, rolling rates, goals, and milestones" do
      user = user_fixture()

      assert {:ok, _later} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => 100,
                 "duration_sec_actual" => 1200,
                 "completed_at" => "2025-02-10T12:00:00Z"
               })

      goal =
        goal_fixture(user, %{
          "burpee_count_target" => 90,
          "burpee_count_baseline" => 10,
          "date_baseline" => "2025-01-01",
          "date_target" => "2025-03-01"
        })

      assert {:ok, backdated} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => 10,
                 "duration_sec_actual" => 1200,
                 "completed_at" => "2025-02-03T12:00:00Z"
               })

      assert backdated.days_since_last == nil
      assert backdated.rate_delta == nil
      assert backdated.rate_avg_rolling_3 == 0.5
      assert backdated.goal_id == nil
      assert Workouts.session_milestones(user, backdated, ~D[2025-02-03]) |> is_list()
      assert Goals.get_goal!(user, goal.id).status == :active
      assert Repo.get!(WorkoutSession, backdated.id).goal_id == nil
    end
  end

  describe "database execution constraints" do
    test "direct SQL enforces the source union, immutable snapshot, and one-way completion" do
      user = user_fixture()
      plan = plan_fixture(user)
      assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
      now = DateTime.utc_now(:second) |> DateTime.to_iso8601()

      assert_raise Exqlite.Error, ~r/workout_sessions_source_snapshot_check/, fn ->
        Repo.query!(
          """
          INSERT INTO workout_sessions (
            user_id, state, source_kind, burpee_type, capture_mode,
            burpee_count_actual, duration_sec_actual, inserted_at, updated_at
          ) VALUES (?, 'started', 'manual', 'six_count', 'logged', NULL, NULL, ?, ?)
          """,
          [user.id, now, now]
        )
      end

      assert_raise Exqlite.Error, ~r/workout_sessions_identity_snapshot_immutable_check/, fn ->
        Repo.query!("UPDATE workout_sessions SET content_hash = 'forged' WHERE id = ?", [
          started.id
        ])
      end

      assert {:ok, completed} =
               Workouts.complete_session(
                 user,
                 started.id,
                 %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
                 :timed
               )

      assert_raise Exqlite.Error, ~r/workout_sessions_state_transition_check/, fn ->
        Repo.query!("UPDATE workout_sessions SET state = 'started' WHERE id = ?", [completed.id])
      end

      assert_raise Exqlite.Error, ~r/workout_sessions_exact_once_completion_check/, fn ->
        Repo.query!("UPDATE workout_sessions SET note_post = 'second write' WHERE id = ?", [
          completed.id
        ])
      end
    end
  end
end
