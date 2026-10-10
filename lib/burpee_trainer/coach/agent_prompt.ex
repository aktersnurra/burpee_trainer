defmodule BurpeeTrainer.Coach.AgentPrompt do
  @moduledoc "Bounded scoped facts shared by conversation, planning, and authoring."
  alias BurpeeTrainer.Coach.{Notebook, Tools, Policy}
  alias BurpeeTrainer.{Levels, Workouts}

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
        :planner ->
          "Plan the owner's next session for the given slot. Prefer a fitting library workout with select_workout, otherwise propose_workout. Do not exceed the next level; level landmarks are 20-minute counts, so scale them for a longer slot. Easier sessions are allowed. Update notebook only with durable facts. Finish with one sentence explaining the choice."

        :coach_page ->
          "Answer briefly. Record durable preferences with update_notebook. Only propose_goal when the owner explicitly asks for a goal. Never invent owner facts."
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
