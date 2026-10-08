defmodule Mix.Tasks.BurpeeTrainer.EvalTest do
  use BurpeeTrainer.DataCase, async: false
  alias BurpeeTrainer.{Accounts, LayoutFixtures, Repo}

  test "actual Mix task runs original suite under cap four with real repair and unknown usage preserved" do
    old_config = Application.get_env(:burpee_trainer, :llm_provider)
    old_req = Req.default_options()

    on_exit(fn ->
      Application.put_env(:burpee_trainer, :llm_provider, old_config)
      Req.default_options(old_req)
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "k",
      model: "synthetic"
    )

    Req.default_options(plug: {Req.Test, __MODULE__})

    repair =
      File.read!("test/fixtures/llm/synthetic_minute_blocks_repair.json") |> Jason.decode!()

    plain = fn layout ->
      %{"choices" => [%{"message" => %{"content" => Jason.encode!(layout)}}]}
    end

    responses =
      [plain.(LayoutFixtures.layout([List.duplicate({30, 5.0, 5.0}, 4)]))] ++
        repair ++ [plain.(LayoutFixtures.layout([[{80, 15.0, 15.0}]]))]

    counter = start_supervised!({Agent, fn -> responses end})

    Req.Test.stub(__MODULE__, fn conn ->
      refute Repo.in_transaction?()
      response = Agent.get_and_update(counter, fn [h | t] -> {h, t} end)
      Req.Test.json(conn, response)
    end)

    before = Path.wildcard(".e2e-artifacts/evals/*.json")
    assert :ok = Mix.Tasks.BurpeeTrainer.Eval.run(["--suite", "authoring", "--max-calls", "4"])

    [output] =
      (Path.wildcard(".e2e-artifacts/evals/*.json") -- before)
      |> Enum.reject(&String.ends_with?(&1, ".owner.json"))

    result = output |> File.read!() |> Jason.decode!()
    assert result["total"]["calls"] == 4
    assert result["total"]["successes"] == 3
    assert result["total"]["repairs_succeeded"] == 1
    assert result["total"]["prompt_tokens"] == nil
    assert result["total"]["completion_tokens"] == nil
    assert result["total"]["known_prompt_tokens"] == 166
    assert result["total"]["known_completion_tokens"] == 94
    assert result["total"]["cost_usd"] == nil
    assert result["total"]["unknown_cost_calls"] == 2
    assert result["total"]["missing_prompt_usage_calls"] == 2

    assert Enum.map(result["scenarios"], & &1["id"]) == [
             "even_no_pauses",
             "minute_blocks_two_pauses",
             "navy_seal_80",
             "unbroken_single_set"
           ]

    assert List.last(result["scenarios"])["failure_reason"] == "llm_budget_exhausted"
    assert Accounts.get_user(result["owner"]["id"]) == nil
    assert Agent.get(counter, & &1) == []
  end

  test "task rejects absent cap before starting an evaluation" do
    assert_raise Mix.Error, ~r/--max-calls is required/, fn ->
      Mix.Tasks.BurpeeTrainer.Eval.run(["--suite", "authoring"])
    end
  end
end
