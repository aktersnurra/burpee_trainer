defmodule BurpeeTrainer.Evals.ApprovalPreviewTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, Repo}
  alias BurpeeTrainer.Evals.{ApprovalPreview, Scenarios}
  alias BurpeeTrainer.Coach.LlmCall
  alias BurpeeTrainer.Workouts.WorkoutPlan

  test "real scoped approval and keyed replay validate, errors remain failures and charges survive preview" do
    scope = scope_fixture()
    foreign = scope_fixture()
    [scenario] = Scenarios.load!("authoring", "minute_blocks_two_pauses")
    {:ok, input} = Scenarios.prepare(scenario)

    # The pauses the coach reads from the scenario's note.
    {:ok, request} =
      input.request
      |> BurpeeTrainer.Coach.WorkoutRequest.to_map()
      |> Map.put("timed_rests", [
        %{"start_sec" => 660, "duration_sec" => 60},
        %{"start_sec" => 1080, "duration_sec" => 40}
      ])
      |> BurpeeTrainer.Coach.WorkoutRequest.new()

    input = %{input | request: request}

    BurpeeTrainer.ReplayProvider.stub(
      __MODULE__,
      "test/fixtures/llm/synthetic_minute_blocks_two_pauses.json"
    )

    assert {:ok, prepared} =
             Coach.prepare_plan(scope, input.instruction, input.request,
               config: [
                 enabled: true,
                 url: "https://provider.test/v1",
                 api_key: "k",
                 model: "synthetic"
               ],
               req: Req.new(plug: {Req.Test, __MODULE__})
             )

    assert {:ok, %{approval_validated: true, publication_rolled_back: true}} =
             ApprovalPreview.validate(scope, prepared)

    assert Repo.get_by(WorkoutPlan, approval_key: prepared.approval_key) == nil

    assert [%{prompt_tokens: 83, completion_tokens: 47, cost_usd: 0.0001, outcome: "ok"}] =
             Repo.all(LlmCall)

    assert {:error, %{code: :design_workspace_changed}} =
             ApprovalPreview.validate(foreign, prepared)

    assert {:error, _} = ApprovalPreview.validate(scope, %{prepared | definition: %{}})
    assert {:ok, existing} = Coach.approve_plan(scope, prepared)

    assert {:error, _} =
             ApprovalPreview.validate(scope, %{
               prepared
               | definition: Map.put(prepared.definition, "name", "Different canonical candidate")
             })

    assert Repo.get!(WorkoutPlan, existing.id).request_text == prepared.text
  end
end
