defmodule BurpeeTrainer.Coach.PlanNextWorkoutJob do
  @moduledoc "Durable planning for an eligible slot; completed days schedule at the next local boundary."
  use Oban.Worker,
    queue: :coach,
    max_attempts: 3,
    unique: [
      keys: [:user_id, :slot_key],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias BurpeeTrainer.{Accounts, UserTime, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Policy, Agent}
  @impl true
  def perform(%Oban.Job{args: %{"user_id" => id, "slot_key" => key}})
      when is_integer(id) and id > 0 and is_binary(key) do
    with %Accounts.User{} = user <- Accounts.get_user(id),
         scope = Scope.for_user(user),
         {:ok, slot} <- Policy.required_slot(scope, DateTime.utc_now(:second)),
         true <- slot.slot_key == key and slot.home_state == :workout_needed,
         {:ok, _} <- Agent.run(scope, :planner, nil, slot: slot) do
      :ok
    else
      nil ->
        {:cancel, :user_missing}

      false ->
        {:cancel, :slot_changed}

      # A changed selection means the owner chose during the run; a retry would override them.
      {:error, %{code: code}}
      when code in [:provider_unavailable, :llm_budget_exhausted, :home_selection_changed] ->
        {:cancel, code}

      {:error, error} ->
        {:error, error}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  @spec enqueue(Scope.t()) :: :ok | {:error, term()}
  def enqueue(%Scope{} = scope) do
    Repo.immediate_transaction(fn ->
      case admit(scope) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Plans the current slot automatically at most once: a later Home visit never re-plans a
  slot whose first job already ran, failed or was cancelled. Retries use `enqueue/1`.
  """
  @spec enqueue_first(Scope.t()) :: :ok | {:error, term()}
  def enqueue_first(%Scope{} = scope) do
    with {:ok, slot} <- Policy.required_slot(scope, DateTime.utc_now(:second)),
         :workout_needed <- slot.home_state,
         {:ok, _} <-
           %{"user_id" => scope.user.id, "slot_key" => slot.slot_key}
           |> new(unique: [keys: [:user_id, :slot_key], period: :infinity, states: :all])
           |> Oban.insert() do
      :ok
    else
      state when state in [:week_complete, :done_today] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Admits the job inside the caller's transaction; a failure never rolls it back."
  @spec admit(Scope.t()) :: :ok | {:error, term()}
  def admit(%Scope{} = scope) do
    with {:ok, slot, at} <- target_slot(scope, DateTime.utc_now(:second)),
         :workout_needed <- slot.home_state,
         {:ok, _} <-
           %{"user_id" => scope.user.id, "slot_key" => slot.slot_key}
           |> new(scheduled_at: at)
           |> Oban.insert() do
      :ok
    else
      state when state in [:week_complete, :done_today] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec target_slot(Scope.t(), DateTime.t()) ::
          {:ok, Policy.slot(), DateTime.t()} | {:error, term()}
  def target_slot(%Scope{user: user} = scope, now) do
    with {:ok, slot} <- Policy.required_slot(scope, now) do
      if slot.home_state == :done_today do
        with {:ok, context} <- UserTime.context(user, now),
             {:ok, local} <-
               UserTime.resolve_local(Date.add(context.date, 1), ~T[00:00:00], context.timezone),
             {:ok, at} <- DateTime.shift_zone(local, "Etc/UTC"),
             {:ok, next_slot} <- Policy.required_slot(scope, at) do
          {:ok, next_slot, at}
        end
      else
        {:ok, slot, now}
      end
    end
  end
end
