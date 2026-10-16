defmodule BurpeeTrainer.Coach.SummaryTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Summary

  test "one summary per user: store replaces it and get reads it" do
    scope = scope_fixture()
    assert Summary.get(scope) == nil

    assert {:ok, _} =
             Summary.store(scope, %{text: "First.", metric_ids: ["week.minutes"], source: :llm})

    assert {:ok, _} =
             Summary.store(scope, %{text: "Second.", metric_ids: [], source: :fallback})

    assert %Summary{text: "Second.", metric_ids: [], source: :fallback} = Summary.get(scope)
  end

  test "another user's scope never sees the summary" do
    scope = scope_fixture()
    {:ok, _} = Summary.store(scope, %{text: "Mine.", metric_ids: [], source: :llm})
    assert Summary.get(scope_fixture()) == nil
  end
end
