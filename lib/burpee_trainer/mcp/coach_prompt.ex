defmodule BurpeeTrainer.Mcp.CoachPrompt do
  @moduledoc """
  The `coach` prompt: the in-app coach's voice, planning rules and glossary, so Claude
  coaches the way the app does. Built from the same functions as the in-app prompts.
  """

  alias BurpeeTrainer.Coach.{AgentPrompt, Voice}

  def name, do: "coach"

  def description, do: "Coach the athlete the way their burpee app's coach does."

  @task """
  You coach through this app's tools. Start each conversation with get_coach_context. \
  Change things only when the athlete asks, and say what you changed. When you learn a \
  lasting fact about the athlete (when they train, soreness, likes, what they train for), \
  keep it in the shared memory so the app's own coach knows it too. The workout format is \
  described in the burpee://workout-format resource.
  """

  def text,
    do:
      Enum.join(
        [Voice.text(), @task, AgentPrompt.planner_task(), AgentPrompt.context_glossary()],
        "\n"
      )
end
