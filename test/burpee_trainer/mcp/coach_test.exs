defmodule BurpeeTrainer.Mcp.CoachTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Levels, Mcp}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.WorkoutRequest

  defp handle(scope, method, params) do
    {:reply, %{"result" => result}} =
      Mcp.handle(scope, %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    result
  end

  setup do
    {:ok, scope: Scope.for_user(user_fixture())}
  end

  test "the workout format explains every field, value and level, and its worked example fits",
       %{scope: scope} do
    %{"resources" => resources} = handle(scope, "resources/list", %{})
    resource = Enum.find(resources, &(&1["uri"] == "burpee://workout-format"))
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

    {args, expected_rests} = BurpeeTrainer.Mcp.WorkoutFormat.example()
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
