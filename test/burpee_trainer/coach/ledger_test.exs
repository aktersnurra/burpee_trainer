defmodule BurpeeTrainer.Coach.LedgerTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Ledger

  test "reservations count against the scoped rolling cap and are finalized in place" do
    scope = scope_fixture()
    attrs = %{purpose: "plan_next", run_id: Ecto.UUID.generate(), model: "m"}
    assert {:ok, call} = Ledger.reserve(scope, attrs, daily_cap: 1)
    assert Ledger.calls_today(scope) == 1
    assert {:error, :llm_budget_exhausted} = Ledger.reserve(scope, attrs, daily_cap: 1)
    assert {:ok, _} = Ledger.reserve(scope_fixture(), attrs, daily_cap: 1)
    assert :ok = Ledger.finish(scope, call.id, %{outcome: "ok", duration_ms: 2, cost_usd: 0.25})
    assert Ledger.calls_today(scope) == 1

    assert {:error, :not_found} =
             Ledger.finish(scope_fixture(), call.id, %{outcome: "ok", duration_ms: 2})
  end

  test "cost caps include in-flight reservations" do
    scope = scope_fixture()
    attrs = %{purpose: "layout", run_id: Ecto.UUID.generate(), model: "m"}

    assert {:ok, _} =
             Ledger.reserve(scope, attrs, daily_cost_cap_usd: 1.0, reservation_cost_usd: 0.6)

    assert {:error, :llm_budget_exhausted} =
             Ledger.reserve(scope, attrs, daily_cost_cap_usd: 1.0, reservation_cost_usd: 0.6)
  end

  test "concurrent in-flight reservations respect the scoped run cap without relaxing daily caps" do
    scope = scope_fixture()
    attrs = %{purpose: "layout", run_id: Ecto.UUID.generate(), model: "m"}

    results =
      1..8
      |> Task.async_stream(fn _ -> Ledger.reserve(scope, attrs, run_cap: 1) end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :llm_budget_exhausted})) == 7
    assert {:ok, _} = Ledger.reserve(scope, %{attrs | run_id: Ecto.UUID.generate()}, run_cap: 1)
    assert {:ok, _} = Ledger.reserve(scope_fixture(), attrs, run_cap: 1)

    assert {:error, :llm_budget_exhausted} =
             Ledger.reserve(scope, %{attrs | run_id: Ecto.UUID.generate()},
               daily_cap: 2,
               run_cap: 100
             )
  end

  test "caller overrides cannot relax configured daily cost or reservation estimates" do
    previous = Application.get_env(:burpee_trainer, :llm_budget, [])
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_budget, previous) end)

    Application.put_env(:burpee_trainer, :llm_budget,
      daily_cost_cap_usd: 0.5,
      reservation_cost_usd: 0.4
    )

    scope = scope_fixture()
    attrs = %{purpose: "layout", run_id: Ecto.UUID.generate(), model: "m"}

    assert {:ok, _} =
             Ledger.reserve(scope, attrs, daily_cost_cap_usd: 1.0, reservation_cost_usd: 0.1)

    assert {:error, :llm_budget_exhausted} =
             Ledger.reserve(scope, attrs,
               daily_cost_cap_usd: 1.0,
               reservation_cost_usd: 0.1,
               run_cap: 100
             )
  end
end
