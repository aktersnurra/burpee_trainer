defmodule BurpeeTrainer.Insights.NarrateJob do
  @moduledoc "One bounded narration job per owned completed session."
  use Oban.Worker,
    queue: :coach,
    max_attempts: 1,
    unique: [keys: [:user_id, :session_id], period: :infinity]

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Insights.Narrator

  def enqueue(%Scope{} = scope, session) do
    Repo.immediate_transaction(fn ->
      case admit(scope, session) do
        {:ok, job} -> job
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Admits the job inside the caller's transaction; a failure never rolls it back."
  def admit(%Scope{user: user}, %{id: id, user_id: user_id}) when user.id == user_id,
    do: %{"user_id" => user.id, "session_id" => id} |> new() |> Oban.insert()

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "session_id" => session_id}}) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id),
         scope = Scope.for_user(user),
         %{state: :completed} = session <- Workouts.get_session(scope, session_id),
         {:ok, _} <- Narrator.narrate(scope, session) do
      BurpeeTrainer.Home.broadcast_changed(scope)
      :ok
    else
      nil -> {:cancel, :session_not_owned}
      {:error, reason} -> {:cancel, reason}
      _ -> {:cancel, :session_not_completed}
    end
  end
end
