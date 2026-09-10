defmodule BurpeeTrainer.Workouts.FinalizationTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Memory

  test "enclosing rollback emits no finalization event" do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user)
    Phoenix.PubSub.subscribe(BurpeeTrainer.PubSub, "workout_finalized")

    assert {:error, :forced} =
             Repo.transaction(fn ->
               assert {:ok, _} = Workouts.publish_draft(user, draft.id)
               Repo.rollback(:forced)
             end)

    refute_received {:workout_finalized, _}
    assert {:ok, %{state: :draft}} = Workouts.get_draft(user, draft.id)
  end

  test "memory rejects foreign, draft, missing and mismatched context identities" do
    user = user_fixture()
    other = user_fixture()
    draft = workout_plan_draft_fixture(user)
    assert {:error, _} = Memory.record_finalized_workout(user.id, draft.id, nil)
    plan = plan_fixture(user)
    assert {:error, _} = Memory.record_finalized_workout(other.id, plan.id, nil)
    assert {:error, _} = Memory.record_finalized_workout(user.id, plan.id, 999)
    assert {:error, _} = Memory.record_finalized_workout(user.id, -1, nil)
    assert Memory.global_context(other).workout_memories == []
  end

  test "memory includes only accepted instructions for this finalized plan" do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user)
    alias BurpeeTrainer.Coach.Context
    {:ok, context} = Context.ensure_session(user, draft, "draft:#{draft.id}")
    draft |> Ecto.Changeset.change(design_session_id: context.id) |> Repo.update!()

    for {text, status, target} <- [
          {"Accepted", "accepted", draft.id},
          {"Failed", "failed", draft.id},
          {"Other plan", "accepted", -1}
        ] do
      attempt = Ecto.UUID.generate()
      {:ok, _} = Context.append(user, context.id, attempt, :instruction, %{"text" => text})

      {:ok, _} =
        Context.append(user, context.id, attempt, :outcome, %{
          "status" => status,
          "pending_draft_id" => target
        })
    end

    {:ok, plan} = Workouts.publish_draft(user, draft.id)
    assert :ok = Memory.record_finalized_workout(user.id, plan.id, context.id)
    drain_coach_memory_tasks()
    assert [memory] = Memory.global_context(user).workout_memories
    assert memory.workout_reason["accepted_instructions"] == ["Accepted"]
    {:ok, _} = Workouts.archive_plan(user, plan.id)
    assert :ok = Memory.record_finalized_workout(user.id, plan.id, context.id)
    assert [^memory] = Memory.global_context(user).workout_memories
  end

  test "memory stores scoped facts and does not alter global settings" do
    user = user_fixture()
    plan = plan_fixture(user, %{request_text: "Less rest in this workout"})
    assert :ok = Memory.record_finalized_workout(user.id, plan.id, nil)
    assert :ok = Memory.record_finalized_workout(user.id, plan.id, nil)
    context = Memory.global_context(user)
    assert context.settings == %{}
    assert [memory] = context.workout_memories
    assert memory.facts["content_hash"] == plan.content_hash
    assert memory.workout_reason["scope"] == "workout"
  end
end
