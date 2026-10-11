defmodule BurpeeTrainer.Coach.AgentPrompt do
  @moduledoc "Bounded scoped facts shared by conversation, planning, and authoring."
  alias BurpeeTrainer.Coach.{Notebook, Tools, Policy, Voice}
  alias BurpeeTrainer.{Levels, Workouts}

  @planner_task """
  Plan the athlete's next session. Prefer a saved or built-in workout that fits, with \
  select_workout; otherwise design one with propose_workout. Never go above the level after \
  their current one; easier sessions are fine. For a session longer than 20 minutes, compare \
  its reps per 20 minutes with the landmarks. Save only lasting facts to the notebook. The \
  rationale appears under the workout: one sentence in the voice above on why this session \
  suits them now. Finish with one sentence explaining your choice.
  """

  @coach_page_task """
  Answer what the athlete asked in at most three sentences. Save lasting preferences and \
  facts they tell you with update_notebook. Use propose_goal only when they ask for a goal; \
  they confirm it themselves.
  """

  @context_glossary """
  The context that follows is JSON. notebook: what you have saved about the athlete. goals: \
  their active and proposed goals. current_level: the level they hold now. landmarks: the \
  reps each level needs in 20 minutes, per burpee type. recent_sessions: their latest \
  sessions first, with reps, duration_sec, pace_sec (seconds per rep) and their feedback. \
  slot: their next session, with its burpee_type and duration_sec; strategy catch_up means \
  a longer weekend session that makes up missed minutes; completed_sec, remaining_sec and \
  weekly_target_sec describe this week's training time.
  """

  def context(scope, slot \\ nil) do
    {:ok, goals} = Tools.Goals.call(scope, %{}, %{})
    sessions = Workouts.list_recent_training_sessions(scope)

    %{
      notebook: Notebook.get(scope).body,
      goals: goals["goals"] |> Enum.take(20),
      current_level: Levels.current_level(Workouts.list_sessions(scope)),
      slot: slot,
      recent_sessions: sessions |> Enum.take(10) |> Enum.map(&Tools.History.summary/1),
      landmarks:
        Enum.map(Levels.all_levels(), fn level ->
          %{
            level: level,
            six_count: Levels.threshold(level, :six_count),
            navy_seal: Levels.threshold(level, :navy_seal)
          }
        end)
    }
  end

  def messages(scope, surface, input, notebook, slot) do
    slot =
      slot ||
        case Policy.required_slot(scope, DateTime.utc_now(:second)) do
          {:ok, s} -> s
          _ -> nil
        end

    rule =
      case surface do
        :planner -> Voice.text() <> "\n" <> @planner_task <> "\n" <> @context_glossary
        :coach_page -> Voice.text() <> "\n" <> @coach_page_task <> "\n" <> @context_glossary
      end

    messages = [
      %{role: "system", content: rule},
      %{
        role: "system",
        content: Jason.encode!(Map.put(context(scope, slot), :notebook, notebook.body))
      }
    ]

    if surface == :coach_page, do: messages ++ [%{role: "user", content: input}], else: messages
  end
end
