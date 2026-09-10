defmodule BurpeeTrainer.Coach.MemorySubscriberTest do
  use BurpeeTrainer.DataCase, async: false

  test "sandbox drain waits for memory work before releasing the owner" do
    user = BurpeeTrainer.Fixtures.user_fixture()
    parent = self()

    {:ok, task} =
      Task.Supervisor.start_child(BurpeeTrainer.CoachMemoryTaskSupervisor, fn ->
        send(parent, {:memory_waiting, self()})

        receive do
          :read ->
            assert BurpeeTrainer.Repo.get!(BurpeeTrainer.Accounts.User, user.id).id == user.id
        after
          5_000 -> flunk("memory task was not released")
        end

        send(parent, :memory_read)
      end)

    assert_receive {:memory_waiting, ^task}
    send(task, :read)
    assert :ok = drain_coach_memory_tasks()
    assert_received :memory_read
    assert Task.Supervisor.children(BurpeeTrainer.CoachMemoryTaskSupervisor) == []
  end

  test "subscriber processes one event without replay or retries" do
    parent = self()
    tasks = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

    start_supervised!(
      {BurpeeTrainer.Coach.MemorySubscriber,
       name: __MODULE__.Subscriber,
       task_supervisor: tasks,
       record: fn user, plan, context ->
         send(parent, {:recorded, user, plan, context})
         raise "callback failure"
       end}
    )

    Phoenix.PubSub.broadcast(
      BurpeeTrainer.PubSub,
      "workout_finalized",
      {:workout_finalized, %{user_id: 101, workout_plan_id: 202, design_session_id: nil}}
    )

    assert_receive {:recorded, 101, 202, nil}
    _ = :sys.get_state(__MODULE__.Subscriber)
    refute_received {:recorded, 101, 202, nil}
  end
end
