defmodule BurpeeTrainer.Coach.AuthoringBudgetTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, LayoutFixtures, Repo}
  alias BurpeeTrainer.Coach.{WorkoutRequest, LlmCall}
  @config [enabled: true, url: "https://provider.test/v1", api_key: "k", model: "m"]
  test "one actual UUID budgets every repair; cap 1 blocks second provider transport" do
    scope = scope_fixture()
    run_id = Ecto.UUID.generate()
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :transport)

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => Jason.encode!(LayoutFixtures.layout([[{10, 15.0, 15.0}]], "Too slow"))
            }
          }
        ]
      })
    end)

    {:ok, request} = request()

    assert {:error, %{code: :llm_budget_exhausted}} =
             Coach.prepare_plan(scope, "ten reps", request,
               req: Req.new(plug: {Req.Test, __MODULE__}),
               config: @config,
               run_id: run_id,
               budget: [run_cap: 1]
             )

    assert_receive :transport
    refute_received :transport
    assert [%{run_id: ^run_id}] = Repo.all(LlmCall)
  end

  test "both genuine repair transports record the same caller run" do
    scope = scope_fixture()
    run_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {Agent,
         fn ->
           [
             LayoutFixtures.layout([[{10, 15.0, 15.0}]]),
             LayoutFixtures.layout([[{10, 12.0, 12.0}]])
           ]
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      answer = Agent.get_and_update(pid, fn [head | tail] -> {head, tail} end)
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => Jason.encode!(answer)}}]})
    end)

    {:ok, request} = request()

    assert {:ok, _} =
             Coach.prepare_plan(scope, "ten reps", request,
               req: Req.new(plug: {Req.Test, __MODULE__}),
               config: @config,
               run_id: run_id,
               budget: [run_cap: 2]
             )

    assert [run_id, run_id] == Enum.map(Repo.all(LlmCall), & &1.run_id)
  end

  defp request,
    do:
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 120,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })
end
