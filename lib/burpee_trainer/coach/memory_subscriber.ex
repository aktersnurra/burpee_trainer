defmodule BurpeeTrainer.Coach.MemorySubscriber do
  use GenServer
  alias BurpeeTrainer.Coach.Memory

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def init(opts) do
    Phoenix.PubSub.subscribe(BurpeeTrainer.PubSub, "workout_finalized")

    {:ok,
     %{
       tasks: Keyword.get(opts, :task_supervisor, BurpeeTrainer.CoachMemoryTaskSupervisor),
       record: Keyword.get(opts, :record, &Memory.record_finalized_workout/3)
     }}
  end

  def handle_info({:workout_finalized, ids}, state) do
    Task.Supervisor.start_child(state.tasks, fn ->
      try do
        state.record.(ids.user_id, ids.workout_plan_id, ids.design_session_id)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
