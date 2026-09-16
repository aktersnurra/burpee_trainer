defmodule BurpeeTrainer.Workouts.HomeEntryStateTest do
  use BurpeeTrainer.DataCase

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error, WorkoutPlan, WorkoutSession}

  @now ~U[2026-09-09 12:00:00Z]

  test "classifies only a user with no persisted Home or training evidence as bootstrap" do
    for {label, arrange, expected} <- cases() do
      user = user_fixture()
      {:ok, slot} = Policy.required_slot(user, @now)
      arrange.(user, slot)
      before = rows()

      assert Workouts.home_entry_state(user, slot) == {:ok, expected}, label
      assert rows() == before, label
    end
  end

  test "rejects malformed slots" do
    assert {:error, %Error{}} =
             Workouts.home_entry_state(user_fixture(), %{
               slot_key: "",
               slot_date: nil,
               home_state: :workout_needed
             })
  end

  test "returns an unavailable error when its valid-slot query fails" do
    user = user_fixture()
    {:ok, slot} = Policy.required_slot(user, @now)
    before = rows()

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

    try do
      assert {:error, %Error{code: :home_entry_state_unavailable}} =
               Workouts.home_entry_state(user, slot)
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      assert rows() == before
    end
  end

  test "does not treat another user's evidence as this user's evidence" do
    existing_user = user_fixture()
    {:ok, existing_slot} = Policy.required_slot(existing_user, @now)
    plan_fixture(existing_user)
    current_recommendation(existing_user, existing_slot)
    session_from_plan_fixture(existing_user, Workouts.list_library(existing_user) |> hd())

    fresh_user = user_fixture()
    {:ok, fresh_slot} = Policy.required_slot(fresh_user, @now)
    before = rows()

    assert Workouts.home_entry_state(fresh_user, fresh_slot) == {:ok, :bootstrap}
    assert rows() == before
  end

  defp cases do
    [
      {"fresh", &fresh/2, :bootstrap},
      {"owned draft", &owned_draft/2, :existing},
      {"owned published", &owned_published/2, :existing},
      {"owned archived", &owned_archived/2, :existing},
      {"current built-in pin", &current_builtin_pin/2, :existing},
      {"historical recommendation", &historical_recommendation/2, :existing},
      {"historical manual session only", &historical_manual_session/2, :existing},
      {"completed built-in session", &completed_builtin_session/2, :existing},
      {"completed video session", &completed_video_session/2, :existing}
    ]
  end

  defp fresh(_user, _slot), do: :ok
  defp owned_draft(user, _slot), do: workout_plan_draft_fixture(user)
  defp owned_published(user, _slot), do: plan_fixture(user)

  defp owned_archived(user, _slot) do
    draft = workout_plan_draft_fixture(user)
    {:ok, published} = Workouts.publish_draft(user, draft.id)
    {:ok, _archived} = Workouts.archive_plan(user, published.id)
  end

  defp current_builtin_pin(user, slot), do: current_recommendation(user, slot)

  defp historical_recommendation(user, slot),
    do:
      current_recommendation(user, %{
        slot
        | slot_key: "historical:" <> slot.slot_key,
          slot_date: Date.add(slot.slot_date, -7)
      })

  defp historical_manual_session(user, slot) do
    completed_at = DateTime.add(@now, -86_400, :second)
    assert Date.compare(DateTime.to_date(completed_at), slot.slot_date) == :lt

    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged,
      burpee_type: :six_count,
      completed_at: completed_at,
      burpee_count_actual: 25,
      duration_sec_actual: 120
    })

    assert Repo.aggregate(from(p in WorkoutPlan, where: p.user_id == ^user.id), :count) == 0

    assert Repo.aggregate(from(r in CoachRecommendation, where: r.user_id == ^user.id), :count) ==
             0
  end

  defp completed_builtin_session(user, _slot) do
    built_in = Enum.find(Workouts.list_library(user), &(&1.origin == :built_in))
    session_from_plan_fixture(user, built_in)
  end

  defp completed_video_session(user, _slot) do
    video = video_fixture()
    {:ok, started} = Workouts.start_video(user, video.id, Ecto.UUID.generate())

    {:ok, _completed} =
      Workouts.complete_session(
        user,
        started.id,
        %{"burpee_count_actual" => 25, "duration_sec_actual" => 120},
        :timed
      )
  end

  defp current_recommendation(user, slot),
    do:
      Workouts.ensure_recommendation(user, %{slot_key: slot.slot_key, slot_date: slot.slot_date})

  defp rows,
    do: %{
      plans: Repo.aggregate(WorkoutPlan, :count),
      recs: Repo.aggregate(CoachRecommendation, :count),
      sessions: Repo.aggregate(WorkoutSession, :count)
    }
end
