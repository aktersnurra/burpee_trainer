defmodule BurpeeTrainer.Analytics.CallBudget do
  @moduledoc "Trusted owner-bound absolute reservation ceiling shared across serial evaluation arms."
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Ledger
  @enforce_keys [:owner_id, :ledger_run_id, :ceiling]
  defstruct @enforce_keys

  def new(%Scope{user: %{id: id}}, ceiling) when is_integer(ceiling) and ceiling >= 0 do
    %__MODULE__{owner_id: id, ledger_run_id: Ecto.UUID.generate(), ceiling: ceiling}
  end

  def usage(%Scope{user: %{id: id}} = scope, %__MODULE__{owner_id: id} = budget) do
    with {:ok, counts} <- Ledger.reservation_count(scope, budget.ledger_run_id) do
      {:ok, Map.put(counts, :remaining, max(budget.ceiling - counts.reservations, 0))}
    end
  end

  def usage(_scope, %__MODULE__{}), do: {:error, :budget_owner_mismatch}

  def client_options(scope, budget, purpose, opts \\ []) do
    allowance = Keyword.get(opts, :call_allowance, 8)

    with :ok <- valid_allowance(allowance),
         {:ok, counts} <- usage(scope, budget),
         cap = min(budget.ceiling, counts.reservations + min(8, allowance)),
         true <- cap > counts.reservations do
      {:ok,
       [
         ledger: %{scope: scope, purpose: purpose, run_id: budget.ledger_run_id},
         budget: [run_cap: cap]
       ]}
    else
      false -> {:error, :llm_budget_exhausted}
      error -> error
    end
  end

  defp valid_allowance(n) when is_integer(n) and n >= 0, do: :ok
  defp valid_allowance(_), do: {:error, :invalid_call_allowance}
end
