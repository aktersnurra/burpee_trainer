defmodule BurpeeTrainer.Evals.RunnerTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Coach.LlmCall
  alias BurpeeTrainer.Evals.{Runner, Scenarios}
  @config [enabled: true, url: "https://provider.test/v1", api_key: "k", model: "synthetic"]

  setup do
    root = Path.expand(".e2e-artifacts/combined/eval-tests/#{Ecto.UUID.generate()}")

    %{
      root: root,
      opts: [
        config: @config,
        req: Req.new(plug: {Req.Test, __MODULE__}),
        output_dir: root,
        recordings_dir: Path.join(root, "recordings")
      ]
    }
  end

  test "cap one prevents genuine repair transport and preserves measured usage before cleanup", %{
    opts: opts
  } do
    BurpeeTrainer.ReplayProvider.stub(
      __MODULE__,
      "test/fixtures/llm/synthetic_minute_blocks_repair.json"
    )

    foreign = user_fixture()

    result =
      Runner.run(
        %{suite: "authoring", max_calls: 1, only: "minute_blocks_two_pauses", record: true},
        opts
      )

    assert result.total.calls == 1

    assert [
             %{
               failure_reason: "llm_budget_exhausted",
               success: false,
               calls: 1,
               prompt_tokens: 83,
               completion_tokens: 47,
               cost_usd: 0.0001
             }
           ] = result.scenarios

    assert Accounts.get_user(result.owner.id) == nil
    assert Accounts.get_user(foreign.id)
    assert Repo.aggregate(LlmCall, :count) == 0

    assert [response] =
             File.read!(Path.join(opts[:recordings_dir], "minute_blocks_two_pauses.json"))
             |> Jason.decode!()

    assert response["usage"]["prompt_tokens"] == 83
    assert File.exists?(result.output_path)
  end

  test "cap four is shared over the whole run; real approval preview leaves ledger intact", %{
    opts: opts
  } do
    responses =
      File.read!("test/fixtures/llm/synthetic_minute_blocks_repair.json") |> Jason.decode!()

    counter = start_supervised!({Agent, fn -> responses ++ responses end})

    Req.Test.stub(__MODULE__, fn conn ->
      refute Repo.in_transaction?()
      response = Agent.get_and_update(counter, fn [h | t] -> {h, t} end)
      Req.Test.json(conn, response)
    end)

    [scenario] = Scenarios.load!("authoring", "minute_blocks_two_pauses")

    result =
      Runner.run(
        %{suite: "authoring", max_calls: 4, only: nil, record: false},
        Keyword.put(opts, :scenarios, [
          scenario,
          Map.put(scenario, "id", "second"),
          Map.put(scenario, "id", "third")
        ])
      )

    assert result.total.calls == 4
    assert result.total.repairs_succeeded == 2
    assert result.total.prompt_tokens == 332
    assert result.total.completion_tokens == 188
    assert_in_delta result.total.cost_usd, 0.0004, 0.0000001
    assert [a, b, c] = result.scenarios
    assert a.approval_validated and b.approval_validated
    assert a.publication_rolled_back and b.publication_rolled_back
    assert c.failure_reason == "llm_budget_exhausted"
    assert Enum.uniq(Enum.map(result.calls, & &1.run_id)) == [result.run_id]
    assert Enum.uniq(Enum.map(result.calls, & &1.user_id)) == [result.owner.id]
    assert Repo.aggregate(BurpeeTrainer.Workouts.WorkoutPlan, :count, :id) == 1
    assert Accounts.get_user(result.owner.id) == nil
  end

  test "provider exception cleans exact checkpointed identity", %{opts: opts, root: root} do
    foreign = user_fixture()
    Req.Test.stub(__MODULE__, fn _ -> raise "eval transport exception" end)

    assert_raise RuntimeError, "eval transport exception", fn ->
      Runner.run(
        %{suite: "authoring", max_calls: 1, only: "minute_blocks_two_pauses", record: false},
        opts
      )
    end

    [path] = Path.wildcard(Path.join(root, "*.owner.json"))
    owner = path |> File.read!() |> Jason.decode!()
    assert Accounts.get_user(owner["id"]) == nil
    assert Accounts.get_user(foreign.id)
  end
end
