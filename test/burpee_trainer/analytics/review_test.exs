defmodule BurpeeTrainer.Analytics.ReviewTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Analytics
  alias BurpeeTrainer.Analytics.{Review, Trace}
  alias BurpeeTrainer.AnalyticsProviderPlug, as: Provider
  @config [enabled: true, url: "https://recorded.test/chat", api_key: "local", model: "recorded"]
  @query %{
    "action" => "query",
    "interpretation" => "count",
    "intent" => "count",
    "sql" => "SELECT count(*) AS n FROM sessions"
  }
  @final %{
    "action" => "final",
    "output" => %{
      "status" => "answered",
      "interpretation" => "count",
      "answer" => "Zero",
      "findings" => [%{"text" => "Zero", "evidence_ids" => ["q1"]}],
      "limitations" => []
    }
  }
  defp judgment(choice),
    do: %{
      "answers" => %{"query_review" => %{"choice" => choice, "confidence" => 0.8}},
      "usage" => %{"cost" => 0.01}
    }

  defp opts(mode, analyst, reviewer),
    do: [
      config: @config,
      req: Provider.request(analyst),
      review_mode: mode,
      review: [config: @config, req: Provider.request(reviewer)]
    ]

  test "strict choice validation rejects unexpected questions, rationale and probabilities" do
    assert {:ok, %{"reason_source" => "code"}} = Review.validate(judgment("proceed")["answers"])

    assert {:error, :review_unavailable} =
             Review.validate(%{
               "query_review" => %{"choice" => "proceed", "rationale" => "not supported"}
             })

    assert {:error, :review_unavailable} =
             Review.validate(%{"query_review" => %{"choice" => "proceed", "confidence" => 3}})

    assert {:error, :review_unavailable} = Review.validate(%{"other" => %{"choice" => "proceed"}})
  end

  test "shadow objections are recorded but never enter analyst context or change output" do
    scope = scope_fixture()

    assert {:ok, output} =
             Analytics.analyze(
               scope,
               "count",
               opts(:shadow, [@query, @final], [judgment("revise_query")])
             )

    assert output["status"] == "answered"

    assert {:ok, %{"judgments" => [%{"choice" => "revise_query"}]}} =
             Trace.fetch(scope, output["trace_id"])

    requests = drain([])
    analyst = Enum.filter(requests, &Map.has_key?(&1, "messages"))
    assert [_, _] = analyst

    refute Enum.any?(
             analyst,
             &String.contains?(Jason.encode!(&1["messages"]), "Reviewer selected")
           )
  end

  test "enforce revises boundedly, clarifies, and fails closed on malformed reviewer" do
    assert {:ok, %{"status" => "budget_exhausted"}} =
             Analytics.analyze(
               scope_fixture(),
               "count",
               opts(
                 :enforce,
                 [@query, @query, @query],
                 List.duplicate(judgment("revise_query"), 3)
               )
             )

    assert {:ok, %{"status" => "needs_clarification"}} =
             Analytics.analyze(
               scope_fixture(),
               "improved",
               opts(:enforce, [@query], [judgment("clarify_with_user")])
             )

    assert {:error, %{code: :review_unavailable}} =
             Analytics.analyze(
               scope_fixture(),
               "count",
               opts(:enforce, [@query], [judgment("unknown")])
             )
  end

  test "off spends no review call; missing shadow config is explicit and enforce fails" do
    scope = scope_fixture()
    assert {:ok, _} = Analytics.analyze(scope, "count", opts(:off, [@query, @final], []))
    assert llm_call_count(scope) == 2
    base = [config: @config, review: [config: [enabled: false]]]

    assert {:ok, %{"limitations" => [limitation]}} =
             Analytics.analyze(
               scope_fixture(),
               "count",
               base ++ [req: Provider.request([@query, @final]), review_mode: :shadow]
             )

    assert String.contains?(limitation, "unreviewed")

    assert {:error, %{code: :review_unavailable}} =
             Analytics.analyze(
               scope_fixture(),
               "count",
               base ++ [req: Provider.request([@query]), review_mode: :enforce]
             )
  end

  defp drain(acc) do
    receive do
      {:analytics_request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
