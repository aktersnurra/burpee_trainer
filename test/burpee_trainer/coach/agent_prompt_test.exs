defmodule BurpeeTrainer.Coach.AgentPromptTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.AgentPrompt

  test "both planning surfaces receive the supplied slot and only the athlete's history" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user, %{burpee_count_actual: 75, duration_sec_actual: 1200})
    free_form_session_fixture(user_fixture(), %{burpee_count_actual: 300})
    slot = %{burpee_type: :navy_seal, duration_sec: 2400}

    for surface <- [:planner, :planner_create] do
      [_rule, %{role: "system", content: memory}, %{role: "system", content: content}] =
        AgentPrompt.messages(scope, surface, nil, slot)

      assert memory =~ "USER PROFILE"

      context = Jason.decode!(content)
      assert context["slot"] == %{"burpee_type" => "navy_seal", "duration_sec" => 2400}
      assert [%{"reps" => 75, "duration_sec" => 1200}] = context["recent_sessions"]
    end
  end

  test "a longer slot comes with its reps already counted for the fatigue" do
    scope = scope_fixture()

    free_form_session_fixture(scope.user, %{
      burpee_type: "navy_seal",
      burpee_count_actual: 70,
      duration_sec_actual: 1200
    })

    slot = %{burpee_type: :navy_seal, duration_sec: 2400}
    [_rule, _memory, %{content: content}] = AgentPrompt.messages(scope, :planner, nil, slot)

    # Repeat 70 per twenty minutes: forty minutes is 105 at most, not 140.
    assert %{"max_reps_per_20" => 70, "slot_reps" => %{"max" => 105}} =
             Jason.decode!(content)["progression"]
  end

  test "the conversation so far comes before the new message, in order" do
    scope = scope_fixture()
    history = [{"Can Thursday be mornings?", "Yes, 7:00."}, {"And Friday?", "Rest."}]

    [_rule, _memory, _context | turns] =
      AgentPrompt.messages(scope, :coach_page, "Thanks", nil, history)

    assert Enum.map(turns, & &1.role) == ~w[user assistant user assistant user]
    assert Enum.at(turns, 1).content == Jason.encode!(%{"reply" => "Yes, 7:00."})
    assert List.last(turns) == %{role: "user", content: "Thanks"}
  end
end
