defmodule BurpeeTrainer.Coach.AgentPromptTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{AgentPrompt, Voice}

  @glossary ~w[notebook goals current_level landmarks recent_sessions slot]

  test "the planner speaks in the voice, explains its context and caps at a 20-minute rate" do
    scope = scope_fixture()
    [rule, context] = AgentPrompt.messages(scope, :planner, nil, %{body: ""}, nil)

    assert String.starts_with?(rule.content, Voice.text())
    for key <- @glossary, do: assert(rule.content =~ key)
    assert rule.content =~ "reps per 20 minutes"
    assert rule.content =~ "What the coach knows"
    refute rule.content =~ "scale them for a longer slot"
    assert Map.has_key?(Jason.decode!(context.content), "recent_sessions")
  end

  test "the coach page speaks in the voice, briefly, and ends with the athlete's message" do
    scope = scope_fixture()

    [rule, _context, message] =
      AgentPrompt.messages(scope, :coach_page, "How am I doing?", %{body: ""}, nil)

    assert String.starts_with?(rule.content, Voice.text())
    for key <- @glossary, do: assert(rule.content =~ key)
    assert rule.content =~ "at most three sentences"
    assert rule.content =~ "What the coach knows"
    assert message == %{role: "user", content: "How am I doing?"}
  end
end
