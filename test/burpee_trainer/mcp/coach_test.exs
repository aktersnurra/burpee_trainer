defmodule BurpeeTrainer.Mcp.CoachTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Levels, Mcp}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{AgentPrompt, Policy, Voice, WorkoutRequest}

  defp handle(scope, method, params) do
    {:reply, %{"result" => result}} =
      Mcp.handle(scope, %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    result
  end

  setup do
    {:ok, scope: Scope.for_user(user_fixture())}
  end

  test "get_coach_context is what the in-app coach reads before it answers", %{scope: scope} do
    result = handle(scope, "tools/call", %{"name" => "get_coach_context", "arguments" => %{}})

    slot =
      case Policy.required_slot(scope, DateTime.utc_now(:second)) do
        {:ok, slot} -> slot
        _ -> nil
      end

    expected = AgentPrompt.context(scope, slot) |> Jason.encode!() |> Jason.decode!()
    assert result["structuredContent"] == expected
    refute result["isError"]
  end

  test "the coach prompt is the in-app coach's voice, rules and glossary", %{scope: scope} do
    %{"prompts" => prompts} = handle(scope, "prompts/list", %{})
    assert Enum.map(prompts, & &1["name"]) == ["coach"]

    %{"messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => text}}]} =
      handle(scope, "prompts/get", %{"name" => "coach"})

    assert text =~ Voice.text()
    assert text =~ AgentPrompt.context_glossary()
    assert text =~ AgentPrompt.planner_task()
    assert text =~ "get_coach_context"
  end

  test "the workout format explains every field and value, and each level's reps",
       %{scope: scope} do
    %{"resources" => [resource]} = handle(scope, "resources/list", %{})
    assert resource["uri"] == "burpee://workout-format"

    %{"contents" => [%{"uri" => "burpee://workout-format", "text" => text}]} =
      handle(scope, "resources/read", %{"uri" => "burpee://workout-format"})

    properties = WorkoutRequest.json_schema().properties

    for {field, schema} <- properties do
      assert text =~ "`#{field}`", "#{field} is not explained"

      for value <- Map.get(schema, :enum, []) do
        assert text =~ "`#{value}`", "#{field} #{value} is not explained"
      end
    end

    for level <- Levels.all_levels(), type <- [:six_count, :navy_seal] do
      assert text =~ Integer.to_string(Levels.threshold(level, type))
    end
  end

  test "the workout format's worked example fits to the rests its text gives" do
    {args, expected_rests} = BurpeeTrainer.Mcp.WorkoutFormat.example()
    text = BurpeeTrainer.Mcp.WorkoutFormat.text()

    assert {:ok, definition} = BurpeeTrainer.Mcp.Workouts.definition(args)

    assert for(%{"kind" => "rest", "duration_sec" => d} <- definition["events"], do: d) ==
             expected_rests

    assert text =~ "So the rests are 20 s and 60 s."

    exact = put_in(args, ["phases", Access.at(0), "rests"], [%{"sec" => 20}, %{"sec" => 52}])
    assert {:error, reason} = BurpeeTrainer.Mcp.Workouts.definition(exact)
    assert reason =~ "8 s before"
  end

  test "an unknown prompt or resource is a protocol error", %{scope: scope} do
    for {method, params} <- [
          {"prompts/get", %{"name" => "nope"}},
          {"resources/read", %{"uri" => "burpee://nope"}}
        ] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Mcp.handle(scope, %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => method,
                 "params" => params
               })
    end
  end

  test "initialize advertises tools, prompts and resources", %{scope: scope} do
    result = handle(scope, "initialize", %{})
    assert Map.keys(result["capabilities"]) |> Enum.sort() == ~w[prompts resources tools]
  end
end
