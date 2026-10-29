defmodule BurpeeTrainer.Coach.MemoryJobTest do
  use BurpeeTrainer.DataCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Exchange, Memory, MemoryJob}

  @config [
    enabled: true,
    url: "https://provider.test/v1/chat/completions",
    api_key: "k",
    model: "m"
  ]
  defp opts, do: [config: @config, req: Req.new(plug: {Req.Test, __MODULE__})]

  defp reply(content) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:request, request})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}]
      })
    end)
  end

  test "what the coach learns writes its note again; an unchanged memory does not" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user)

    reply(%{"ops" => []})
    assert {:ok, []} = MemoryJob.keep(scope, %{kind: "conversation"}, opts())
    refute_enqueued(worker: BurpeeTrainer.Coach.SummaryJob)

    reply(%{"ops" => [%{"op" => "add", "text" => "Left knee gets sore after jumps"}]})
    assert {:ok, [_]} = MemoryJob.keep(scope, %{kind: "conversation"}, opts())
    assert_enqueued(worker: BurpeeTrainer.Coach.SummaryJob, args: %{"user_id" => scope.user.id})
  end

  test "the model reads the notes and the event, and its ops change the memory" do
    scope = scope_fixture()
    {:ok, _} = Memory.apply_ops(scope, [%{"op" => "add", "text" => "Trains at 7:00"}])
    [old] = Memory.list(scope)

    reply(%{
      "ops" => [
        %{"op" => "replace", "id" => old.id, "text" => "Trains at 18:00"},
        %{"op" => "add", "text" => "Left knee gets sore after jumps"}
      ]
    })

    event = %{kind: "conversation", athlete: "Evenings now, and my knee hurts", coach: "Noted."}
    assert {:ok, changes} = MemoryJob.keep(scope, event, opts())

    assert_received {:request, request}
    assert request["response_format"]["json_schema"]["name"] == "coach_memory"
    [_task, %{"content" => input}] = request["messages"]

    assert %{"notes" => [%{"id" => _, "text" => "Trains at 7:00"}], "event" => _} =
             Jason.decode!(input)

    assert Enum.map(changes, &{&1.kind, &1.text}) == [
             forgot: "Trains at 7:00",
             noted: "Trains at 18:00",
             noted: "Left knee gets sore after jumps"
           ]

    assert Enum.map(Memory.list(scope), & &1.text) == [
             "Trains at 18:00",
             "Left knee gets sore after jumps"
           ]
  end

  test "an unusable answer, or no provider, changes nothing" do
    scope = scope_fixture()
    reply(%{"something" => "else"})
    assert {:error, _} = MemoryJob.keep(scope, %{kind: "conversation"}, opts())
    assert {:error, _} = MemoryJob.keep(scope, %{kind: "conversation"}, [])
    assert Memory.list(scope) == []
  end

  test "an exchange always admits a job; a session only when it carries feedback" do
    scope = scope_fixture()
    {:ok, exchange} = Exchange.record(scope, "Mornings?", "Yes.")
    assert {:ok, _} = MemoryJob.admit_exchange(scope, exchange)
    assert_enqueued(worker: MemoryJob, args: %{user_id: scope.user.id, exchange_id: exchange.id})

    plain = free_form_session_fixture(scope.user)
    assert :ok = MemoryJob.admit_session(scope, plain)

    noted = %{plain | note_post: "Knee hurt on the jumps"}
    assert {:ok, _} = MemoryJob.admit_session(scope, noted)
  end
end
