defmodule BurpeeTrainer.Insights.NarratorTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Insights, Repo}
  alias BurpeeTrainer.Insights.Narrator
  alias BurpeeTrainer.Coach.LlmCall
  import Ecto.Query

  @config [
    enabled: true,
    url: "https://provider.test/v1/chat/completions",
    api_key: "k",
    model: "m"
  ]
  defp opts, do: [config: @config, req: Req.new(plug: {Req.Test, __MODULE__})]

  defp reply(content) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["response_format"]["json_schema"]["name"] == "session_insight"
      assert request["response_format"]["json_schema"]["strict"] == true

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 7, "cost" => 0.001}
      })
    end)
  end

  test "valid structured narration stored once and recorded in actual scoped ledger" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope.user)

    content = %{
      "headline" => "Steady progress",
      "points" => [%{"text" => "25 reps last session.", "metric_ids" => ["session.reps"]}]
    }

    reply(content)
    assert {:ok, insight} = Narrator.narrate(scope, session, opts())
    assert insight.source == "llm"
    assert insight.points["items"] == content["points"]
    assert {:ok, replay} = Narrator.narrate(scope, session, opts())
    assert replay.id == insight.id
    assert llm_call_count(scope) == 1
    call = Repo.one!(from c in LlmCall, where: c.user_id == ^scope.user.id)
    assert call.purpose == "insight"
    assert call.prompt_tokens == 11
    assert call.completion_tokens == 7
    assert call.outcome == "ok"
  end

  test "the insight prompt speaks in the voice about the latest session" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope.user)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:messages, Jason.decode!(body)["messages"]})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "{}"}}]})
    end)

    Narrator.narrate(scope, session, opts())
    assert_receive {:messages, [%{"role" => "system", "content" => prompt}]}
    assert String.starts_with?(prompt, BurpeeTrainer.Coach.Voice.text())
    assert prompt =~ "No numbers in the headline"
    assert prompt =~ "metric_ids"
  end

  test "fabrication and provider disabled produce validated deterministic fallback" do
    scope = scope_fixture()
    first = free_form_session_fixture(scope.user)

    reply(%{
      "headline" => "Nice",
      "points" => [%{"text" => "999 reps.", "metric_ids" => ["session.reps"]}]
    })

    assert {:ok, %{source: "fallback", headline: "Session saved"}} =
             Narrator.narrate(scope, first, opts())

    second = free_form_session_fixture(scope.user)

    assert {:ok, %{source: "fallback"}} =
             Narrator.narrate(scope, second, config: [enabled: false])
  end

  test "budget exhaustion falls back before actual transport" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope.user)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :unexpected_transport)
      Req.Test.json(conn, %{})
    end)

    assert {:ok, %{source: "fallback"}} =
             Narrator.narrate(scope, session, Keyword.put(opts(), :budget, daily_cap: 0))

    refute_received :unexpected_transport
    assert llm_call_count(scope) == 0
  end

  test "empty provider headline falls back instead of failing persistence" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope.user)
    reply(%{"headline" => "", "points" => []})

    assert {:ok, %{source: "fallback", headline: "Session saved"}} =
             Narrator.narrate(scope, session, opts())
  end

  test "delayed narration cites the exact warmup target even with a newer completion" do
    scope = scope_fixture()

    ordinary =
      free_form_session_fixture(scope.user, %{
        "burpee_count_actual" => 10,
        "duration_sec_actual" => 120
      })

    plan = plan_fixture(scope.user)

    target =
      session_from_plan_fixture(scope.user, plan, %{
        "burpee_count_actual" => 7,
        "duration_sec_actual" => 60,
        "tags" => "warmup"
      })

    newer =
      free_form_session_fixture(scope.user, %{
        "completed_at" => target.completed_at,
        "burpee_count_actual" => 999,
        "duration_sec_actual" => 1200
      })

    assert newer.id > target.id
    assert DateTime.compare(ordinary.completed_at, target.completed_at) != :gt

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [_, encoded] = String.split(hd(request["messages"])["content"], "Metrics: ", parts: 2)
      metrics = Jason.decode!(encoded)
      assert metrics["session.reps"]["value"] == 7
      assert metrics["session.duration_min"]["value"] == 1
      assert metrics["week.minutes"]["value"] == 22

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" =>
                Jason.encode!(%{
                  "headline" => "Session saved",
                  "points" => [
                    %{"text" => "7 reps last session.", "metric_ids" => ["session.reps"]}
                  ]
                })
            }
          }
        ]
      })
    end)

    assert {:ok, %{source: "llm"} = insight} = Narrator.narrate(scope, target, opts())
    assert insight.session_id == target.id

    assert insight.points["items"] == [
             %{"text" => "7 reps last session.", "metric_ids" => ["session.reps"]}
           ]

    assert Insights.for_session(scope, newer.id) == nil
  end

  test "foreign session has no provider or ledger effects" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope_fixture().user)
    assert {:error, :session_not_owned} = Narrator.narrate(scope, session, opts())
    assert llm_call_count(scope) == 0
    assert Insights.for_session(scope, session.id) == nil
  end
end
