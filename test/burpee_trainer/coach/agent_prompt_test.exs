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
    refute rule.content =~ "scale them for a longer slot"
    assert Map.has_key?(Jason.decode!(context.content), "recent_sessions")
  end
end
