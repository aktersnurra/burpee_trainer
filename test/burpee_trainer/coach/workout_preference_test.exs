defmodule BurpeeTrainer.Coach.WorkoutPreferenceTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.{Policy, Selector, WorkoutPreference}
  alias BurpeeTrainer.Coach.Tools.SelectWorkout
  alias BurpeeTrainer.Workouts

  @now ~U[2026-10-26 12:00:00Z]

  defp session(plan_id, days_ago, preference),
    do: %{
      plan_id: plan_id,
      preference_feedback: preference,
      completed_at: DateTime.add(@now, -days_ago, :day),
      id: days_ago
    }

  describe "decide/2" do
    test "a workout's latest preference wins, and silence does not erase it" do
      sessions = [session(1, 1, nil), session(1, 3, :avoid), session(1, 9, :choose_again)]
      assert WorkoutPreference.decide(sessions, @now) == %{1 => :avoid}
    end

    test "each workout keeps its own preference" do
      sessions = [session(1, 2, :avoid), session(2, 1, :choose_again)]
      assert WorkoutPreference.decide(sessions, @now) == %{1 => :avoid, 2 => :choose_again}
    end

    test "a preference lapses after four weeks" do
      sessions = [session(1, 27, :avoid), session(2, 29, :avoid)]
      assert WorkoutPreference.decide(sessions, @now) == %{1 => :avoid}
    end

    test "a session with no saved workout carries no preference" do
      assert WorkoutPreference.decide([session(nil, 1, :avoid)], @now) == %{}
    end
  end

  describe "in the choices the coach makes" do
    @chat [enabled: true, url: "https://provider.test/v1", api_key: "k", model: "m"]
    @decisions [
      enabled: true,
      url: "https://provider.test/api/alpha/decisions",
      api_key: "k",
      model: "typesafe/jev-1.14",
      min_confidence: 0.6
    ]

    defp slot_and_scope do
      scope = scope_fixture()
      {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
      {scope, slot}
    end

    defp finished_with(scope, plan, preference) do
      session_from_plan_fixture(scope.user, plan, %{"preference_feedback" => preference})
    end

    test "the decision model is not offered a workout the athlete asked to avoid" do
      {scope, slot} = slot_and_scope()
      liked = plan_fixture(scope.user, %{target_reps: 30, target_duration_sec: slot.duration_sec})

      avoided =
        plan_fixture(scope.user, %{target_reps: 31, target_duration_sec: slot.duration_sec})

      finished_with(scope, avoided, "avoid")
      finished_with(scope, liked, "choose_again")

      test = self()

      Req.Test.stub(__MODULE__.Decisions, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:decision_request, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "answers" => %{
            "workout" => %{
              "type" => "choice",
              "choice" => "create_new",
              "confidence" => 0.9,
              "probabilities" => %{"create_new" => 0.9}
            }
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "cost" => 0.0}
        })
      end)

      Req.Test.stub(__MODULE__.Chat, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(%{"reply" => "Done"})}}]
        })
      end)

      Selector.plan(scope, slot,
        config: @chat,
        req: Req.new(plug: {Req.Test, __MODULE__.Chat}),
        decisions: [config: @decisions, req: Req.new(plug: {Req.Test, __MODULE__.Decisions})]
      )

      assert_received {:decision_request, %{"questions" => q}}
      criteria = q["workout"]["criteria"]
      refute Map.has_key?(criteria, "workout_#{avoided.id}")
      assert criteria["workout_#{liked.id}"]["athlete_feedback"] == "wants to do it again"
    end

    test "the planner's select tool refuses a workout the athlete asked to avoid" do
      {scope, slot} = slot_and_scope()

      avoided =
        plan_fixture(scope.user, %{target_reps: 30, target_duration_sec: slot.duration_sec})

      finished_with(scope, avoided, "avoid")
      {:ok, before} = Workouts.ensure_home_selection(scope, slot)

      assert {:error, reason} =
               SelectWorkout.call(
                 scope,
                 %{"plan_id" => avoided.id, "rationale" => "Ready"},
                 %{slot: slot, expected_selection: before}
               )

      assert reason =~ "avoid"
    end
  end
end
