defmodule BurpeeTrainer.Coach.AgentTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Agent, Notebook}

  @config [
    enabled: true,
    url: "https://provider.test/v1/chat/completions",
    api_key: "k",
    model: "m"
  ]
  defp call(name, args),
    do: %{
      "choices" => [
        %{
          "message" => %{
            "content" => nil,
            "tool_calls" => [
              %{"id" => "c", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}
            ]
          }
        }
      ]
    }

  defp final(text),
    do: %{"choices" => [%{"message" => %{"content" => Jason.encode!(%{"reply" => text})}}]}

  defp responses(list) do
    pid = start_supervised!({Elixir.Agent, fn -> list end})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end))
    end)

    [config: @config, req: Req.new(plug: {Req.Test, __MODULE__})]
  end

  test "executes tools, advances notebook CAS version, and returns bounded final answer" do
    scope = scope_fixture()

    opts =
      responses([
        call("update_notebook", %{"text" => "Mornings"}),
        call("update_notebook", %{"text" => "Morning short sets"}),
        final("Noted.")
      ])

    assert {:ok, %{reply: "Noted."}} = Agent.run(scope, :coach_page, "I train mornings", opts)
    assert Notebook.get(scope).body == "Morning short sets"
  end

  test "stops at six calls" do
    opts = responses(List.duplicate(call("goals", %{}), 6))

    assert {:error, :agent_budget_exhausted} =
             Agent.run(scope_fixture(), :coach_page, "loop", opts)
  end

  test "planner never executes goal tool and invalid tool arguments are returned without crashing" do
    scope = scope_fixture()
    {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(scope, DateTime.utc_now(:second))

    opts =
      responses([call("propose_goal", %{}), call("history", %{"weeks" => "bad"}), final("ok")])

    assert {:ok, %{reply: "ok"}} = Agent.run(scope, :planner, nil, Keyword.put(opts, :slot, slot))
    assert BurpeeTrainer.Goals.list(scope) == []
  end

  test "a fourth workout proposal ends the run without a seventh model call" do
    scope = scope_fixture()
    {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(scope, DateTime.utc_now(:second))
    opts = responses(List.duplicate(call("propose_workout", %{}), 4))

    assert {:error, :agent_budget_exhausted} =
             Agent.run(scope, :planner, nil, Keyword.put(opts, :slot, slot))
  end
end
