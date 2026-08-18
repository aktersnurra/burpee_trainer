defmodule BurpeeTrainer.WorkoutsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{Error, WorkoutSession}

  describe "library" do
    test "published plans are visible only to their owner while drafts are separate" do
      alice = user_fixture()
      bob = user_fixture()
      alice_plan = plan_fixture(alice, %{name: "Alice intervals"})
      _bob_plan = plan_fixture(bob, %{name: "Bob intervals"})
      draft = workout_plan_draft_fixture(alice, %{name: "Alice draft"})

      assert Enum.any?(Workouts.list_library(alice), &(&1.id == alice_plan.id))
      refute Enum.any?(Workouts.list_library(alice), &(&1.user_id == bob.id))
      refute Enum.any?(Workouts.list_library(alice), &(&1.id == draft.id))
      assert Enum.map(Workouts.list_drafts(alice), & &1.id) == [draft.id]
    end

    test "archived plans remain owned history facts but cannot start" do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, archived} = Workouts.archive_plan(user, plan.id)

      assert archived.state == :archived

      assert {:error, %Error{code: :archived_workout}} =
               Workouts.start_plan(user, archived.id, Ecto.UUID.generate())
    end
  end

  describe "immutable session execution" do
    test "duplicate start delivery resolves to one started row" do
      user = user_fixture()
      plan = plan_fixture(user)
      client_session_id = Ecto.UUID.generate()

      assert {:ok, first} = Workouts.start_plan(user, plan.id, client_session_id)
      assert {:ok, duplicate} = Workouts.start_plan(user, plan.id, client_session_id)
      assert first.id == duplicate.id

      assert Repo.aggregate(
               from(session in WorkoutSession,
                 where:
                   session.user_id == ^user.id and
                     session.client_session_id == ^client_session_id
               ),
               :count
             ) == 1
    end

    test "started plan session remains pinned after the source is archived" do
      user = user_fixture()
      plan = plan_fixture(user, %{name: "Pinned plan", target_reps: 24})
      {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
      {:ok, _archived} = Workouts.archive_plan(user, plan.id)

      assert started.display_name_snapshot == "Pinned plan"
      assert started.program_snapshot == plan.program_json
      assert started.content_hash == plan.content_hash

      assert {:ok, completed} =
               Workouts.complete_session(
                 user,
                 started.id,
                 %{"burpee_count_actual" => 22, "duration_sec_actual" => 1_180},
                 :timed
               )

      assert completed.state == :completed
      assert completed.plan_id == plan.id
      assert completed.program_snapshot == plan.program_json
    end

    test "completed history excludes started rows and retains snapshots after archiving" do
      user = user_fixture()
      plan = plan_fixture(user)
      completed = session_from_plan_fixture(user, plan)
      {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

      assert Enum.map(Workouts.list_sessions(user), & &1.id) == [completed.id]
      assert started.state == :started

      {:ok, _archived} = Workouts.archive_plan(user, plan.id)
      historical = Workouts.get_session!(user, completed.id)
      assert historical.plan_id == plan.id
      assert historical.display_name_snapshot == completed.display_name_snapshot
      assert historical.program_snapshot == completed.program_snapshot
    end

    test "a foreign user cannot resume or complete another user's session" do
      owner = user_fixture()
      stranger = user_fixture()
      plan = plan_fixture(owner)
      {:ok, started} = Workouts.start_plan(owner, plan.id, Ecto.UUID.generate())

      assert {:error, %Error{code: :session_not_owned}} =
               Workouts.resume_session(stranger, started.id)

      assert {:error, %Error{code: :session_not_owned}} =
               Workouts.complete_session(
                 stranger,
                 started.id,
                 %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
                 :logged
               )
    end
  end
end
