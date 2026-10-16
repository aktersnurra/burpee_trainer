defmodule BurpeeTrainer.Evals.ResultsTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Evals.Results

  test "first fit/repair derive from actual layout ledger rows with tokens/cost/failures" do
    call = %{
      purpose: "layout",
      outcome: "ok",
      prompt_tokens: 10,
      completion_tokens: 20,
      cost_usd: 0.01,
      duration_ms: 5
    }

    first = Results.scenario("first", {:ok, %{}}, [call])
    assert first.first_try_fit
    refute first.repaired
    assert first.calls == 1
    assert first.prompt_tokens == 10
    assert first.cost_usd == 0.01

    repaired =
      Results.scenario("repair", {:ok, %{}}, [%{call | outcome: "invalid_response"}, call])

    assert repaired.repaired
    refute repaired.first_try_fit
    assert repaired.calls == 2
    failed = Results.scenario("failed", {:error, %{code: :llm_budget_exhausted}}, [call])
    refute failed.first_try_fit
    assert failed.failure_reason == "llm_budget_exhausted"
    assert failed.outcomes == ["ok"]
  end

  test "missing provider cost is never manufactured as zero" do
    call = %{
      purpose: "layout",
      outcome: "provider_error",
      prompt_tokens: nil,
      completion_tokens: nil,
      cost_usd: nil,
      duration_ms: 0
    }

    result = Results.scenario("unknown", {:error, :provider_error}, [call])
    assert result.cost_usd == nil
    assert result.prompt_tokens == nil
    assert result.completion_tokens == nil
    assert result.known_prompt_tokens == 0
    assert result.known_completion_tokens == 0
    assert Results.total([result]).prompt_tokens == nil
    assert Results.total([result]).completion_tokens == nil
    assert result.unknown_cost_calls == 1
    assert result.known_cost_usd == 0.0
  end

  test "suite totals expose denominators and preserve unknown cost" do
    call = %{
      purpose: "layout",
      outcome: "ok",
      prompt_tokens: 10,
      completion_tokens: 20,
      cost_usd: 0.01,
      duration_ms: 5
    }

    rows = [
      Results.scenario("first", {:ok, %{}}, [call]),
      Results.scenario("repair", {:ok, %{}}, [call, call]),
      Results.scenario("failed", {:error, :provider_error}, [%{call | cost_usd: nil}])
    ]

    total = Results.total(rows)
    assert total.scenarios == 3
    assert total.first_try_fits == 1
    assert total.repairs_succeeded == 1
    assert total.successes == 2
    assert total.first_try_fit_rate == 1 / 3
    assert total.calls == 4
    assert total.prompt_tokens == 40
    assert total.completion_tokens == 80
    assert total.cost_usd == nil
    assert_in_delta total.known_cost_usd, 0.03, 0.000001
    assert Results.total([]).first_try_fit_rate == nil
  end
end
