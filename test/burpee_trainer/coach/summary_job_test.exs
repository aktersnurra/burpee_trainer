defmodule BurpeeTrainer.Coach.SummaryJobTest do
  use BurpeeTrainer.DataCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import BurpeeTrainer.Fixtures
  import Ecto.Query
  alias BurpeeTrainer.{Goals, Repo}
  alias BurpeeTrainer.Coach.{LlmCall, Summary, SummaryJob}
  alias BurpeeTrainer.Coach.Tools.ProposeGoal
  alias BurpeeTrainer.Insights.Validator

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
      assert request["response_format"]["json_schema"]["name"] == "coach_summary"

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 7, "cost" => 0.001}
      })
    end)
  end

  test "a validated reply is stored as the llm summary and recorded in the ledger" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)
    content = %{"text" => "25 reps last session.", "metric_ids" => ["session.reps"]}
    reply(content)

    assert {:ok, %Summary{source: :llm, text: "25 reps last session."}} =
             SummaryJob.summarize(scope, opts())

    assert %Summary{metric_ids: ["session.reps"]} = Summary.get(scope)
    call = Repo.one!(from c in LlmCall, where: c.user_id == ^scope.user.id)
    assert call.purpose == "summary"
  end

  test "the look back is stored with the note; one with an unsupported number is left out" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)

    reply(%{
      "text" => "Keep Thursday.",
      "review" => "Six-count is steady at 25 reps.",
      "metric_ids" => ["session.reps"],
      "replies" => []
    })

    assert {:ok, %Summary{review: "Six-count is steady at 25 reps."}} =
             SummaryJob.summarize(scope, opts())

    reply(%{
      "text" => "Keep Thursday.",
      "review" => "Six-count rose by 999 reps.",
      "metric_ids" => ["session.reps"],
      "replies" => []
    })

    assert {:ok, %Summary{text: "Keep Thursday.", review: nil}} =
             SummaryJob.summarize(scope, opts())
  end

  test "the summary prompt speaks in the voice and aims at goals, or the next level" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:messages, Jason.decode!(body)["messages"]})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "{}"}}]})
    end)

    SummaryJob.summarize(scope, opts())
    assert_receive {:messages, [%{"role" => "system", "content" => prompt}]}
    assert String.starts_with?(prompt, BurpeeTrainer.Coach.Voice.text())
    assert prompt =~ "next level"
    assert prompt =~ "metric_ids"
    # It sits under the headline, so it says what to do rather than restating the numbers.
    assert prompt =~ "what to do next"
    assert prompt =~ "do not restate"
  end

  test "a fabricated number stores a fallback that is itself validated" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)
    reply(%{"text" => "999 reps last session.", "metric_ids" => ["session.reps"]})

    # The fallback reports only a short last week; it never restates the goal or this week.
    assert {:ok, %Summary{source: :fallback} = stored} = SummaryJob.summarize(scope, opts())
    assert stored.text =~ "Last week:"
    refute stored.text =~ "this week"
  end

  test "a disabled provider stores the fallback without a ledger row" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)

    assert {:ok, %Summary{source: :fallback}} =
             SummaryJob.summarize(scope, config: [enabled: false])

    assert llm_call_count(scope) == 0
  end

  test "without a completed session or an active goal nothing is stored" do
    scope = scope_fixture()
    assert :none = SummaryJob.summarize(scope, opts())
    assert Summary.get(scope) == nil
    assert llm_call_count(scope) == 0
  end

  test "the fallback reports only a short last week: the headline shows the goal and the week" do
    metrics = %{
      "week.minutes" => %{value: 0, unit: :minutes, label: "w"},
      "week.target_minutes" => %{value: 80, unit: :minutes, label: "t"},
      "last_week.minutes" => %{value: 50, unit: :minutes, label: "lw"},
      "last_week.target_minutes" => %{value: 80, unit: :minutes, label: "lt"},
      "goal.9.best_reps" => %{value: 90, unit: :reps, label: "b"},
      "goal.9.target_reps" => %{value: 160, unit: :reps, label: "g"},
      "goal.9.days_left" => %{value: 30, unit: :days, label: "d"},
      "goal.3.best_reps" => %{value: 120, unit: :reps, label: "b"},
      "goal.3.target_reps" => %{value: 150, unit: :reps, label: "g"},
      "goal.3.days_left" => %{value: 52, unit: :days, label: "d"}
    }

    summary = SummaryJob.fallback(metrics)

    assert summary["text"] == "Last week: 50 of 80 minutes."
    assert {:ok, _} = Validator.validate_summary(summary, metrics)

    met = %{metrics | "last_week.minutes" => %{value: 80, unit: :minutes, label: "lw"}}
    assert SummaryJob.fallback(met) == nil
  end

  test "confirming a goal admits a summary; dismissing a proposal changes no input and does not" do
    scope = scope_fixture()

    {:ok, %{"goal_id" => id}} = ProposeGoal.call(scope, proposal(), %{})
    assert {:ok, _} = Goals.confirm(scope, id)
    assert [%{args: %{"user_id" => user_id}}] = all_enqueued(worker: SummaryJob)
    assert user_id == scope.user.id

    Repo.delete_all(Oban.Job)
    {:ok, %{"goal_id" => id}} = ProposeGoal.call(scope, proposal(), %{})
    assert {:ok, _} = Goals.dismiss(scope, id)
    assert all_enqueued(worker: SummaryJob) == []
  end

  describe "on_open/2" do
    test "nothing to report is absent and admits nothing" do
      scope = scope_fixture()
      assert {:absent, nil} = SummaryJob.on_open(scope, DateTime.utc_now())
      assert all_enqueued(worker: SummaryJob) == []
    end

    test "a summary written this local week is current and admits nothing" do
      scope = scope_fixture()
      free_form_session_fixture(scope.user)
      {:ok, stored} = Summary.store(scope, %{text: "Fresh.", metric_ids: [], source: :llm})
      assert {:current, %Summary{id: id}} = SummaryJob.on_open(scope, DateTime.utc_now())
      assert id == stored.id
      assert all_enqueued(worker: SummaryJob) == []
    end

    test "a summary from an earlier week, or none with a session, is refreshed by one job" do
      scope = scope_fixture()
      free_form_session_fixture(scope.user)
      assert {:refreshing, nil} = SummaryJob.on_open(scope, DateTime.utc_now())

      {:ok, _} = Summary.store(scope, %{text: "Old.", metric_ids: [], source: :llm})
      age_summary(scope, 8)
      assert {:stale, %Summary{text: "Old."}} = SummaryJob.status(scope, DateTime.utc_now())
      assert {:refreshing, %Summary{text: "Old."}} = SummaryJob.on_open(scope, DateTime.utc_now())
      assert [%{args: %{"user_id" => user_id}}] = all_enqueued(worker: SummaryJob)
      assert user_id == scope.user.id
    end
  end

  test "performing the job broadcasts the stored summary to the owner" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)
    :ok = Summary.subscribe(scope)
    assert :ok = perform_job(SummaryJob, %{user_id: scope.user.id})
    assert_receive {:coach_summary, %Summary{source: :fallback}}
  end

  test "a job that raises still broadcasts, so Home's loader never waits forever" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)
    {:ok, _} = Summary.store(scope, %{text: "Old.", metric_ids: [], source: :llm})

    Repo.update_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^scope.user.id),
      set: [timezone: "Not/A_Zone"]
    )

    :ok = Summary.subscribe(scope)
    assert_raise MatchError, fn -> perform_job(SummaryJob, %{user_id: scope.user.id}) end
    assert_receive {:coach_summary, %Summary{text: "Old."}}
  end

  defp age_summary(scope, days) do
    Repo.update_all(from(s in Summary, where: s.user_id == ^scope.user.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -days, :day)]
    )
  end

  defp proposal do
    %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 150,
      "duration_sec_target" => 1200,
      "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
    }
  end
end
