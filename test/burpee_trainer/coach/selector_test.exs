defmodule BurpeeTrainer.Coach.SelectorTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{LlmCall, Policy, Rationale, SelectionRationale, Selector}
  alias BurpeeTrainer.Workouts

  @chat [enabled: true, url: "https://provider.test/v1", api_key: "k", model: "m"]
  @decisions [
    enabled: true,
    url: "https://provider.test/api/alpha/decisions",
    api_key: "k",
    model: "typesafe/jev-1.14",
    min_confidence: 0.6
  ]

  defp fixture do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    fit = plan_fixture(scope.user, %{target_reps: 30, target_duration_sec: slot.duration_sec})
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)
    {scope, slot, fit, before}
  end

  defp opts do
    [
      config: @chat,
      req: Req.new(plug: {Req.Test, __MODULE__.Chat}),
      decisions: [config: @decisions, req: Req.new(plug: {Req.Test, __MODULE__.Decisions})]
    ]
  end

  defp decide(choice, confidence) do
    test = self()

    Req.Test.stub(__MODULE__.Decisions, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:decision_request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "answers" => %{
          "workout" => %{
            "type" => "choice",
            "choice" => choice,
            "confidence" => confidence,
            "probabilities" => %{choice => confidence}
          }
        },
        "usage" => %{"input_tokens" => 900, "output_tokens" => 12, "cost" => 0.00004}
      })
    end)
  end

  defp final(text),
    do: %{"choices" => [%{"message" => %{"content" => Jason.encode!(%{"reply" => text})}}]}

  # Records the tools each planner request offered and replies without choosing.
  defp chat_without_choice do
    test = self()

    Req.Test.stub(__MODULE__.Chat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      tools =
        body |> Jason.decode!() |> Map.get("tools", []) |> Enum.map(& &1["function"]["name"])

      send(test, {:chat_tools, tools})
      Req.Test.json(conn, final("Done"))
    end)
  end

  test "a confident choice selects the fitting workout with a template rationale and no LLM call" do
    {scope, slot, fit, before} = fixture()

    too_hard =
      plan_fixture(scope.user, %{target_reps: 300, target_duration_sec: slot.duration_sec})

    too_short = plan_fixture(scope.user, %{target_reps: 30, target_duration_sec: 600})
    decide("workout_#{fit.id}", 0.82)
    Req.Test.stub(__MODULE__.Chat, fn _conn -> flunk("the planner LLM was called") end)

    assert {:ok, _} = Selector.plan(scope, slot, opts())

    assert_received {:decision_request, %{"model" => "typesafe/jev-1.14", "questions" => q}}
    offered = Map.keys(q["workout"]["criteria"])
    assert "workout_#{fit.id}" in offered and "create_new" in offered
    refute "workout_#{too_hard.id}" in offered or "workout_#{too_short.id}" in offered

    assert {:ok, selection} = Workouts.ensure_home_selection(scope, slot)
    assert selection.plan.id == fit.id
    assert selection.home_revision == before.home_revision + 1
    assert Workouts.planned_by(scope, slot) == :coach

    assert %LlmCall{purpose: "select", prompt_tokens: 900, cost_usd: 4.0e-5, outcome: "ok"} =
             Repo.get_by!(LlmCall, user_id: scope.user.id)
  end

  for {choice, confidence} <- [{"create_new", 0.9}, {:fit, 0.4}] do
    test "#{inspect(choice)} at #{confidence} has the coach design a workout instead" do
      {scope, slot, fit, before} = fixture()
      choice = if unquote(choice) == :fit, do: "workout_#{fit.id}", else: unquote(choice)
      decide(choice, unquote(confidence))
      chat_without_choice()

      assert {:error, :no_selection} = Selector.plan(scope, slot, opts())
      assert_received {:chat_tools, tools}
      assert Enum.sort(tools) == ["goals", "history", "propose_workout"]
      assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
    end
  end

  test "a failed decision falls back to the full planner" do
    {scope, slot, _fit, before} = fixture()
    Req.Test.stub(__MODULE__.Decisions, &Plug.Conn.send_resp(&1, 503, "{}"))
    chat_without_choice()

    assert {:error, :no_selection} = Selector.plan(scope, slot, opts())
    assert_received {:chat_tools, tools}
    assert "select_workout" in tools and "propose_workout" in tools
    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
  end

  test "every template rationale passes the check Home's rationales must pass" do
    plan = %Workouts.WorkoutPlan{
      burpee_type: :six_count,
      target_reps: 100,
      target_duration_sec: 1200
    }

    for last_reps <- [nil, 80, 100, 120] do
      sessions =
        if last_reps,
          do: [
            %Workouts.WorkoutSession{
              burpee_type: :six_count,
              burpee_count_actual: last_reps,
              duration_sec_actual: 1200
            }
          ],
          else: []

      text = SelectionRationale.text(plan, sessions)
      assert {:ok, ^text} = Rationale.validate(text)
    end
  end
end
