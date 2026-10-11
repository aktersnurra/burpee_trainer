defmodule BurpeeTrainer.Coach.NewRequestTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Coach.WorkoutRequest

  @config [
    enabled: true,
    url: "https://provider.test/v1/chat/completions",
    api_key: "k",
    model: "m"
  ]

  defp opts, do: [config: @config, req: Req.new(plug: {Req.Test, __MODULE__})]

  defp fields do
    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 50,
        "target_duration_sec" => 1200,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => 5.0
      })

    request
  end

  defp reply(content) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      })
    end)
  end

  test "a blank note asks the coach nothing" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("no provider call expected") end)
    assert {:ok, request} = Coach.prepare_new_request(scope_fixture(), fields(), "  ", opts())
    assert request == fields()
  end

  test "the note adds exact sets, pauses and recovery; the fields stay as entered" do
    reply(%{
      "burpee_type" => "navy_seal",
      "target_reps" => 999,
      "target_duration_sec" => 600,
      "pacing_style" => "unbroken",
      "recovery" => "required",
      "timed_rests" => [%{"start_sec" => 600, "duration_sec" => 60}],
      "requested_pace_sec" => nil,
      "set_reps" => [25, 25]
    })

    note = "Two sets of 25, a minute's break at 10:00"
    assert {:ok, request} = Coach.prepare_new_request(scope_fixture(), fields(), note, opts())

    assert %WorkoutRequest{
             burpee_type: "six_count",
             target_reps: 50,
             target_duration_sec: 1200,
             pacing_style: "even",
             requested_pace_sec: 5.0,
             recovery: "required",
             set_reps: [25, 25],
             timed_rests: [%{start_sec: 600, duration_sec: 60}]
           } = request

    assert_receive {:request, body}
    assert body["response_format"]["json_schema"]["schema"]["properties"]["set_reps"]
    assert Enum.any?(body["messages"], &(&1["content"] =~ note))
  end

  test "sets that do not add up to the reps are refused" do
    reply(%{
      "burpee_type" => "six_count",
      "target_reps" => 50,
      "target_duration_sec" => 1200,
      "pacing_style" => "even",
      "recovery" => "required",
      "timed_rests" => [],
      "requested_pace_sec" => nil,
      "set_reps" => [30, 30]
    })

    assert {:error, %BurpeeTrainer.Workouts.Error{code: :note_does_not_fit}} =
             Coach.prepare_new_request(scope_fixture(), fields(), "Two sets of 30", opts())
  end
end
