defmodule BurpeeTrainer.Analytics.CallBudgetTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Analytics.CallBudget
  alias BurpeeTrainer.Coach.Ledger

  test "shared ceiling counts failures and inflight rows, refuses other owners and zero allowance" do
    scope = scope_fixture()
    budget = CallBudget.new(scope, 2)
    assert {:ok, %{reservations: 0, remaining: 2}} = CallBudget.usage(scope, budget)
    assert {:error, :budget_owner_mismatch} = CallBudget.usage(scope_fixture(), budget)

    assert {:error, :llm_budget_exhausted} =
             CallBudget.client_options(scope, budget, "analytics", call_allowance: 0)

    assert {:error, :invalid_call_allowance} =
             CallBudget.client_options(scope, budget, "analytics", call_allowance: -1)

    assert {:ok, opts} = CallBudget.client_options(scope, budget, "analytics", call_allowance: 1)
    attrs = %{purpose: "analytics", run_id: opts[:ledger].run_id, model: "m"}
    assert {:ok, call} = Ledger.reserve(scope, attrs, opts[:budget])
    assert :ok = Ledger.finish(scope, call.id, %{outcome: "timeout"})
    assert {:error, :llm_budget_exhausted} = Ledger.reserve(scope, attrs, opts[:budget])
    assert {:ok, %{reservations: 1, remaining: 1}} = CallBudget.usage(scope, budget)

    assert {:ok, opts2} =
             CallBudget.client_options(scope, budget, "analytics_baseline", call_allowance: 99)

    assert opts2[:budget][:run_cap] == 2
    assert {:ok, _} = Ledger.reserve(scope, attrs, opts2[:budget])
    assert {:ok, %{reservations: 2, remaining: 0, inflight: 1}} = CallBudget.usage(scope, budget)
    assert {:error, :llm_budget_exhausted} = Ledger.reserve(scope, attrs, opts2[:budget])
  end
end
