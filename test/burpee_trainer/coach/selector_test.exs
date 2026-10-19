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

  test "only saved workouts within 10% of the athlete's recent best are offered" do
    {scope, slot, _fit, _before} = fixture()
    recent = DateTime.add(DateTime.utc_now(:second), -2, :day)

    for {type, reps} <- [{slot.burpee_type, 100}, {other_type(slot.burpee_type), 40}] do
      Repo.insert!(%Workouts.WorkoutSession{
        user_id: scope.user.id,
        state: :completed,
        source_kind: :manual,
        display_name_snapshot: "Logged",
        workout_type_snapshot: type,
        burpee_type: type,
        burpee_count_actual: reps,
        duration_sec_actual: 1200,
        completed_at: recent,
        capture_mode: :logged
      })
    end

    pace = fn reps -> div(reps * slot.duration_sec, 1200) end

    within =
      plan_fixture(scope.user, %{target_reps: pace.(105), target_duration_sec: slot.duration_sec})

    # The next level would allow it; 10% above a recent best of 100 does not.
    over =
      plan_fixture(scope.user, %{target_reps: pace.(140), target_duration_sec: slot.duration_sec})

    decide("create_new", 0.9)
    chat_without_choice()

    Selector.plan(scope, slot, opts())

    assert_received {:decision_request, %{"questions" => q}}
    offered = Map.keys(q["workout"]["criteria"])
    assert "workout_#{within.id}" in offered
    refute "workout_#{over.id}" in offered
  end

  defp other_type(:six_count), do: :navy_seal
  defp other_type(:navy_seal), do: :six_count

  test "a confident create_new has the coach design a workout instead" do
    {scope, slot, _fit, before} = fixture()
    decide("create_new", 0.9)
    chat_without_choice()

    assert {:error, :no_selection} = Selector.plan(scope, slot, opts())
    assert_received {:chat_tools, tools}
    assert Enum.sort(tools) == ["goals", "history", "propose_workout"]
    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
  end

  for choice <- ["create_new", :fit] do
    test "an unsure #{inspect(choice)} leaves the choice to the full planner" do
      {scope, slot, fit, before} = fixture()
      choice = if unquote(choice) == :fit, do: "workout_#{fit.id}", else: unquote(choice)
      decide(choice, 0.4)
      chat_without_choice()

      assert {:error, :no_selection} = Selector.plan(scope, slot, opts())
      assert_received {:chat_tools, tools}
      assert "select_workout" in tools and "propose_workout" in tools
      assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
    end
  end

  test "the owner's choice made while the decision is out is kept" do
    {scope, slot, fit, before} = fixture()
    owners = plan_fixture(scope.user, %{target_reps: 31, target_duration_sec: slot.duration_sec})

    Req.Test.stub(__MODULE__.Decisions, fn conn ->
      {:ok, _} = Workouts.select_home_workout(scope, before, owners.id)

      Req.Test.json(conn, %{
        "answers" => %{
          "workout" => %{
            "type" => "choice",
            "choice" => "workout_#{fit.id}",
            "confidence" => 0.9,
            "probabilities" => %{"workout_#{fit.id}" => 0.9}
          }
        },
        "usage" => %{"input_tokens" => 900, "output_tokens" => 12, "cost" => 0.00004}
      })
    end)

    assert {:error, %{code: :home_selection_changed}} = Selector.plan(scope, slot, opts())
    assert {:ok, selection} = Workouts.ensure_home_selection(scope, slot)
    assert selection.plan.id == owners.id
    assert Workouts.planned_by(scope, slot) == :owner
  end

  test "the planner never replaces the owner's choice, even from a current selection" do
    {scope, slot, fit, before} = fixture()
    {:ok, owners} = Workouts.select_home_workout(scope, before, fit.id)

    assert {:error, %{code: :home_selection_changed}} =
             Workouts.select_planned_workout(scope, owners, {:plan, fit.id}, "A steady day.")

    assert Workouts.planned_by(scope, slot) == :owner
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
