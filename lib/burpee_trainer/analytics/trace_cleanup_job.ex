defmodule BurpeeTrainer.Analytics.TraceCleanupJob do
  @moduledoc "Scheduled deletion of expired sensitive traces."
  use Oban.Worker, queue: :coach, max_attempts: 3
  @impl true
  def perform(%Oban.Job{}), do: BurpeeTrainer.Analytics.Trace.delete_expired()
end
