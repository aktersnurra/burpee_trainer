defmodule BurpeeTrainer.Evals.AnalyticsScoreTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Evals.Analytics.{Corpus, Score}

  test "manifest has 25 stable independent cases and five inspected held-outs" do
    cases = Corpus.cases()
    assert Enum.count(cases) == 25
    assert Enum.count(Enum.uniq_by(cases, & &1.id)) == 25
    assert Enum.count(cases, &(&1.partition == :held_out)) == 5
    assert Enum.sort(Enum.uniq(Enum.map(cases, & &1.dataset))) == ["autumn", "spring"]
    assert Enum.all?(cases, &(byte_size(&1.rationale) > 20))
  end

  test "CLI defaults offline and rejects accidental paid admission" do
    alias Mix.Tasks.BurpeeTrainer.Analytics.Eval
    assert Eval.parse!([]).mode == :offline
    assert_raise Mix.Error, fn -> Eval.parse!(["--live"]) end
    assert_raise Mix.Error, fn -> Eval.parse!(["--max-calls", "1"]) end

    assert_raise Mix.Error, fn ->
      Eval.parse!(["--live", "--max-calls", "1", "--owner-opt-in"])
    end

    assert_raise Mix.Error, fn ->
      Eval.parse!([
        "--live",
        "--max-calls",
        "0",
        "--owner-opt-in",
        "--user-id",
        "1",
        "--dataset",
        "spring"
      ])
    end

    assert_raise Mix.Error, fn -> Eval.parse!(["--dataset", "spring", "--dataset", "autumn"]) end
  end

  test "numeric claims are graded against independent answers, not the model's evidence or self-grade" do
    c = hd(Corpus.cases())

    output = %{
      "status" => "answered",
      "answer_rows" => [[295]],
      "evidence" => [%{"id" => "q1", "rows" => [[150]]}],
      "findings" => [%{"evidence_ids" => ["q1"]}]
    }

    assert Score.score(c, %{result: {:ok, output}}).numeric.passed == 0

    assert Score.score(c, %{result: {:ok, Map.put(output, "answer_rows", [[150.0005]])}}).numeric.passed ==
             1

    assert Score.score(c, %{result: {:ok, Map.put(output, "answer_rows", [[150.01]])}}).numeric.passed ==
             0
  end

  test "quoted misleading premise is not itself foreign evidence contamination" do
    c = hd(Corpus.cases())

    output = %{
      "status" => "insufficient_data",
      "answer" => "999999 is not supported by your history.",
      "evidence" => [],
      "findings" => []
    }

    assert Score.score(c, %{result: {:ok, output}}).contamination.passed == 1
  end

  test "review metrics require independent opportunity labels; shadow is not intervention" do
    c = hd(Corpus.cases())
    assert Score.score(c, %{}).review_catches.denominator == 0
    label = %{proposal_valid: false, mode: :enforce, choice: "revise_query", executed: false}
    assert Score.score(c, %{review_adjudications: [label]}).review_catches.passed == 1

    assert Score.score(c, %{review_adjudications: [%{label | mode: :shadow}]}).review_catches.passed ==
             0

    valid = %{label | proposal_valid: true}
    assert Score.score(c, %{review_adjudications: [valid]}).false_objections.passed == 1
  end

  test "scorer rejects wrong math, contamination and invented citations; missing is not zero" do
    c = hd(Corpus.cases())

    good = %{
      result:
        {:ok,
         %{
           "status" => "answered",
           "evidence" => [%{"id" => "q1", "rows" => [[150]]}],
           "findings" => [%{"evidence_ids" => ["q1"]}]
         }}
    }

    assert Score.score(c, good).numeric.passed == 1
    assert Score.score(c, good).evidence.passed == 1

    bad = %{
      result:
        {:ok,
         %{
           "status" => "answered",
           "evidence" => [%{"id" => "q1", "rows" => [[999_999]]}],
           "findings" => [%{"evidence_ids" => ["invented"]}]
         }}
    }

    score = Score.score(c, bad)
    assert score.numeric.passed == 0
    assert score.contamination.passed == 0
    assert score.evidence.passed == 0
    assert Score.score(c, %{result: {:error, :missing_recording}}).numeric.missing == 1
  end
end

defmodule BurpeeTrainer.Evals.AnalyticsTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Analytics.{CallBudget, Executor, Snapshot}
  alias BurpeeTrainer.Evals.Analytics.{Corpus, Runner}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "known-answer SQL and denied probes use actual executor and owned snapshots for both fixtures" do
    for dataset <- Corpus.datasets() do
      scope = install(dataset)
      assert {:ok, snapshot} = Snapshot.build(scope, now: Corpus.now(dataset))
      assert Corpus.matches?(snapshot, dataset)
      assert length(snapshot.rows) == length(dataset["rows"])
      refute Enum.any?(snapshot.rows, &(999_999 in &1))

      for c <- Corpus.cases(), c.dataset == dataset["id"], c.oracle_sql do
        if c.expected["denied"] do
          assert {:error, reason} = Executor.query(snapshot, c.oracle_sql)
          assert reason in [:sql_denied, :sql_error]
        else
          assert {:ok, result} = Executor.query(snapshot, c.oracle_sql)
          assert Enum.sort(result.rows) == Enum.sort(c.expected["rows"])
        end
      end
    end
  end

  test "offline no-call default and explicit live admission" do
    scope = scope_fixture()
    assert {:ok, report} = Runner.run(scope, Corpus.cases())
    assert report.mode == "offline_protocol"
    assert Enum.count(report.records) == 75
    assert llm_call_count(scope) == 0
    assert {:error, :live_opt_in_required} = Runner.run(scope, [], mode: :live, max_calls: 1)

    assert {:error, :positive_call_budget_required} =
             Runner.run(scope, [], mode: :live, owner_opt_in: true, max_calls: 0)
  end

  test "recorded consumer shares last reservation across C B A, denying review repair and next arms" do
    scope = install(Corpus.dataset("spring"))
    budget = CallBudget.new(scope, 1)

    query = %{
      "action" => "query",
      "interpretation" => "actual reps",
      "intent" => "sum",
      "sql" => "SELECT sum(reps_actual) FROM sessions"
    }

    config = [
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    ]

    req = BurpeeTrainer.AnalyticsProviderPlug.request([query])

    assert {:ok, report} =
             Runner.run(scope, [hd(Corpus.cases())],
               mode: :recorded,
               call_budget: budget,
               max_calls: 1,
               arms: [:c, :b, :a],
               baseline_options: [
                 config: config,
                 req: BurpeeTrainer.AnalyticsProviderPlug.request([])
               ],
               analyst_options: [
                 config: config,
                 req: req,
                 review: [config: config, req: BurpeeTrainer.AnalyticsProviderPlug.request([])]
               ]
             )

    assert Enum.count(report.records) == 3
    assert {:ok, %{reservations: 1, remaining: 0, inflight: 0}} = CallBudget.usage(scope, budget)
    assert Enum.all?(report.records, &(&1.usage.after.reservations == 1))
    assert Enum.all?(report.records, &is_nil(&1.cost_usd))
  end

  test "all three real recorded dispatch paths retain calls, citations, off/enforce events and unknown billing" do
    scope = install(Corpus.dataset("spring"))
    c = hd(Corpus.cases())

    config = [
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    ]

    query = %{
      "action" => "query",
      "interpretation" => "actual non-warmup reps",
      "intent" => "sum actual reps",
      "sql" => "SELECT sum(reps_actual) FROM sessions WHERE warmup=0"
    }

    narrative = %{
      "status" => "answered",
      "interpretation" => "actual reps",
      "answer" => "150 reps",
      "findings" => [%{"text" => "150 reps", "evidence_ids" => ["q1"]}],
      "limitations" => []
    }

    final = %{"action" => "final", "output" => narrative}
    req = BurpeeTrainer.AnalyticsProviderPlug.request([query, final, query, final])

    review =
      BurpeeTrainer.AnalyticsProviderPlug.request([
        %{"answers" => %{"query_review" => %{"choice" => "proceed"}}, "usage" => %{}}
      ])

    baseline =
      start_supervised!({Agent, fn -> ["query_history", "final"] end}, id: :baseline_responses)

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.Test.stub(__MODULE__, fn conn ->
      response = Agent.get_and_update(baseline, fn [head | tail] -> {head, tail} end)

      message =
        if response == "final" do
          %{
            "content" =>
              Jason.encode!(
                narrative
                |> put_in(["findings", Access.at(0), "evidence_ids"], ["a1"])
                |> Map.put("answer_rows", [[150]])
              )
          }
        else
          %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "t1",
                "type" => "function",
                "function" => %{"name" => "query_history", "arguments" => "{}"}
              }
            ]
          }
        end

      Req.Test.json(conn, %{
        "choices" => [%{"message" => message}],
        "usage" => %{"prompt_tokens" => 10}
      })
    end)

    assert {:ok, report} =
             Runner.run(scope, [c],
               mode: :recorded,
               max_calls: 8,
               baseline_options: [config: config, req: Req.new(plug: {Req.Test, __MODULE__})],
               analyst_options: [config: config, req: req, review: [config: config, req: review]]
             )

    assert [a, b, c] = report.records
    assert a.usage.after.reservations == 2
    assert b.usage.after.reservations == 4
    assert c.usage.after.reservations == 7
    assert b.review_events.judgments == []
    assert [%{"choice" => "proceed"}] = c.review_events.judgments
    assert b.score.numeric.passed == 1
    assert c.score.numeric.passed == 1
    assert a.score.evidence.passed == 1
    assert a.score.numeric.passed == 1
    assert is_binary(Jason.encode!(report))
    assert Enum.all?(report.records, &is_nil(&1.cost_usd))
  end

  test "recorded timeout retains actual failed reservation and blocks every following arm" do
    scope = install(Corpus.dataset("spring"))

    config = [
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    ]

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.Test.stub(__MODULE__, fn _ ->
      receive do
        :never -> raise "unreachable"
      end
    end)

    req = Req.new(plug: {Req.Test, __MODULE__})

    assert {:ok, report} =
             Runner.run(scope, [hd(Corpus.cases())],
               mode: :recorded,
               max_calls: 1,
               baseline_options: [config: config, req: req],
               analyst_options: [config: config, req: req, review: [config: config, req: req]]
             )

    assert [first, _, _] = report.records
    refute first.result.ok
    assert first.usage.after.reservations == 1
    assert first.usage.after.inflight == 0
    assert [%{outcome: "timeout", cost_usd: nil}] = first.usage.calls
    assert llm_call_count(scope) == 1
  end

  test "failed finalization preserves attempted result and halts with inflight accounting" do
    scope = install(Corpus.dataset("spring"))

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER analytics_eval_finish_failure BEFORE UPDATE ON llm_calls BEGIN SELECT RAISE(ABORT, 'finish failed'); END",
      []
    )

    config = [
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    ]

    req =
      BurpeeTrainer.AnalyticsProviderPlug.request([
        %{"action" => "clarify", "interpretation" => "ambiguous", "question" => "Which metric?"}
      ])

    assert {:error, %{reason: :inflight_reservations, report: report}} =
             Runner.run(scope, [hd(Corpus.cases())],
               mode: :recorded,
               arms: [:b],
               max_calls: 2,
               analyst_options: [config: config, req: req]
             )

    assert [attempt] = report.records
    assert attempt.result.error == :ledger_finalization_failed
    assert attempt.usage.after.inflight == 1
    assert is_nil(attempt.cost_usd)
    assert llm_call_count(scope) == 1
  end

  test "unresolved reservations halt the comparison rather than guessing remaining calls" do
    scope = install(Corpus.dataset("spring"))
    budget = CallBudget.new(scope, 2)

    assert {:ok, _} =
             BurpeeTrainer.Coach.Ledger.reserve(scope, %{
               purpose: "analytics_baseline",
               run_id: budget.ledger_run_id,
               model: "recorded"
             })

    assert {:error, %{reason: :inflight_reservations, report: %{records: []}}} =
             Runner.run(scope, [hd(Corpus.cases())],
               mode: :live,
               owner_opt_in: true,
               max_calls: 2,
               call_budget: budget
             )

    assert llm_call_count(scope) == 1
  end

  test "recorded mode rejects a missing baseline or reviewer transport before any reservation" do
    scope = scope_fixture()

    config = [
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    ]

    assert {:error, :recorded_transport_required} =
             Runner.run(scope, Corpus.cases(),
               mode: :recorded,
               max_calls: 4,
               analyst_options: [
                 config: config,
                 req: BurpeeTrainer.AnalyticsProviderPlug.request([])
               ]
             )

    assert llm_call_count(scope) == 0
  end

  test "supplied shared budget cannot widen the explicit live ceiling" do
    scope = scope_fixture()

    assert {:error, :call_budget_exceeds_ceiling} =
             Runner.run(scope, [],
               mode: :live,
               owner_opt_in: true,
               max_calls: 1,
               call_budget: CallBudget.new(scope, 2)
             )

    assert llm_call_count(scope) == 0
  end

  test "fixture mismatch refuses provider calls and reports partial comparison" do
    scope = scope_fixture()

    assert {:error, %{reason: :fixture_mismatch, report: %{records: []}}} =
             Runner.run(scope, [hd(Corpus.cases())],
               mode: :live,
               owner_opt_in: true,
               max_calls: 1
             )

    assert llm_call_count(scope) == 0
  end

  defp install(dataset) do
    user =
      user_fixture() |> Ecto.Changeset.change(timezone: dataset["timezone"]) |> Repo.update!()

    for row <- dataset["rows"], do: insert_row(user.id, row)
    insert_row(user_fixture().id, hd(dataset["rows"]) |> List.replace_at(6, 999_999))
    Scope.for_user(user)
  end

  defp insert_row(owner, row) do
    [_, at, _, _, type, capture, reps, planned, seconds, planned_seconds, _, warmup | _] = row
    {:ok, at, _} = DateTime.from_iso8601(at)

    %WorkoutSession{
      user_id: owner,
      state: :completed,
      source_kind: :manual,
      completed_at: at,
      burpee_type: enum(type),
      capture_mode: enum(capture),
      burpee_count_actual: reps,
      burpee_count_planned: planned,
      duration_sec_actual: seconds,
      duration_sec_planned: planned_seconds,
      tags: if(warmup == 1, do: "warmup", else: "not-warmup")
    }
    |> Repo.insert!()
  end

  defp enum("six_count"), do: :six_count
  defp enum("navy_seal"), do: :navy_seal
  defp enum("tracked"), do: :tracked
  defp enum("timed"), do: :timed
  defp enum("logged"), do: :logged
end
