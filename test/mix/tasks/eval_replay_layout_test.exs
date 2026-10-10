defmodule BurpeeTrainer.Evals.ReplayLayoutTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Client, RestFitter, WorkoutLayout, WorkoutRequest}
  alias BurpeeTrainer.Evals.Scenarios
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition

  test "explicit synthetic replay passes actual Client ledger, real form request, fitter and compiler" do
    [scenario] = Scenarios.load!("authoring", "minute_blocks_two_pauses")
    assert {:ok, %{request: request}} = Scenarios.prepare(scenario)
    scope = scope_fixture()

    BurpeeTrainer.ReplayProvider.stub(
      __MODULE__,
      "test/fixtures/llm/synthetic_minute_blocks_two_pauses.json"
    )

    assert {:ok, %{content: layout}} =
             Client.chat([],
               config: [
                 enabled: true,
                 url: "https://provider.test/v1",
                 api_key: "k",
                 model: "synthetic"
               ],
               req: Req.new(plug: {Req.Test, __MODULE__}),
               response_format: {"workout_layout", WorkoutLayout.json_schema(request)},
               ledger: %{scope: scope, purpose: "layout", run_id: Ecto.UUID.generate()}
             )

    assert llm_call_count(scope) == 1
    assert {:ok, canonical} = RestFitter.fit(request, layout)
    assert {:ok, definition} = WorkoutDefinition.new(canonical)
    assert :ok = WorkoutRequest.validate_definition(request, definition)
    assert {:ok, _program} = BurpeeTrainer.PlanCompiler.compile(definition)
    assert definition.target_reps == 140
    assert definition.target_duration_sec == 1200
    assert {660_000_000, 60_000_000} in WorkoutRequest.rest_timeline(definition.events)
    assert {1_080_000_000, 40_000_000} in WorkoutRequest.rest_timeline(definition.events)
  end
end
