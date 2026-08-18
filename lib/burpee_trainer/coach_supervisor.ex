defmodule BurpeeTrainer.CoachSupervisor do
  @moduledoc "Supervises disposable coach reconciliation work."

  use Supervisor

  @default_task_supervisor BurpeeTrainer.CoachTaskSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)

    reconciler_options =
      opts
      |> Keyword.get(:reconciler_options, [])
      |> Keyword.put_new(:name, BurpeeTrainer.CoachReconciler)
      |> Keyword.put(:task_supervisor, task_supervisor)

    children = [
      {Task.Supervisor, name: task_supervisor},
      {BurpeeTrainer.CoachReconciler, reconciler_options}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
