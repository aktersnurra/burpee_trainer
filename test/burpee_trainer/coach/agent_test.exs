defmodule BurpeeTrainer.Coach.AgentTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Agent

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

  test "executes tools and returns a bounded final answer" do
    scope = scope_fixture()
    opts = responses([call("goals", %{}), call("history", %{}), final("Keep going.")])
    assert {:ok, %{reply: "Keep going."}} = Agent.run(scope, :coach_page, "How am I doing?", opts)
  end

  test "on the Coach page the reply is heard as it is written, after the tools have run" do
    scope = scope_fixture()
    pid = start_supervised!({Elixir.Agent, fn -> [call("goals", %{}), final("Keep going.")] end})

    Req.Test.stub(__MODULE__, fn conn ->
      BurpeeTrainer.ProviderStream.reply(
        conn,
        Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end)
      )
    end)

    test_pid = self()

    assert {:ok, %{reply: "Keep going."}} =
             Agent.run(scope, :coach_page, "How am I doing?",
               config: @config,
               req: Req.new(plug: {Req.Test, __MODULE__}),
               on_reply: &send(test_pid, {:reply, &1})
             )

    assert_received {:reply, "Keep going."}
    # The tool call wrote no reply, and none of the JSON around it is ever heard.
    refute_received {:reply, _}
  end

  test "the coach keeps its memory as it talks, reading the snapshot it began with" do
    scope = scope_fixture()

    {:ok, _} =
      BurpeeTrainer.Coach.Memory.write(scope, "user", [
        %{"action" => "add", "content" => "Trains at 7:00"}
      ])

    test_pid = self()

    answers = [
      call("memory", %{
        "target" => "user",
        "operations" => [%{"action" => "patch", "old_text" => "7:00", "content" => "18:00"}]
      }),
      final("Evenings it is.")
    ]

    {:ok, pid} = Elixir.Agent.start_link(fn -> answers end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})
      Req.Test.json(conn, Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end))
    end)

    opts = [config: @config, req: Req.new(plug: {Req.Test, __MODULE__})]

    assert {:ok, %{reply: "Evenings it is.", memory_written?: true}} =
             Agent.run(scope, :coach_page, "I train evenings now", opts)

    assert Enum.map(BurpeeTrainer.Coach.Memory.list(scope), & &1.text) == ["Trains at 18:00"]

    assert_received {:request, first}
    assert_received {:request, second}
    # The prompt's snapshot stays as the turn began; the tool's answer is live.
    snapshot = fn request -> Enum.at(request["messages"], 1)["content"] end
    assert snapshot.(first) =~ "Trains at 7:00"
    assert snapshot.(second) =~ "Trains at 7:00"
    assert List.last(second["messages"])["content"] =~ "Trains at 18:00"
  end

  test "a reply that wrote nothing says so" do
    opts = responses([final("Noted.")])

    assert {:ok, %{memory_written?: false}} =
             Agent.run(scope_fixture(), :coach_page, "Hi", opts)
  end

  test "a reply with anything besides the reply is rejected" do
    reply = %{"reply" => "Thursday stays unbroken.", "suggestions" => ["Make it shorter"]}
    opts = responses([%{"choices" => [%{"message" => %{"content" => Jason.encode!(reply)}}]}])

    assert {:error, :invalid_provider_response} =
             Agent.run(scope_fixture(), :coach_page, "Thursday?", opts)
  end

  test "planner never executes goal tool and invalid tool arguments are returned without crashing" do
    scope = scope_fixture()
    {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(scope, DateTime.utc_now(:second))

    opts =
      responses([
        call("propose_goal", %{}),
        call("history", %{"weeks" => "bad"}),
        final("ok"),
        final("ok")
      ])

    assert {:error, :no_selection} =
             Agent.run(scope, :planner, nil, Keyword.put(opts, :slot, slot))

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
