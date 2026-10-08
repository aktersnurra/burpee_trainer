defmodule BurpeeTrainer.Coach.AuthoringPrompt do
  @moduledoc "Bounded scoped facts plus the active instruction, confirmed constraints and verified edit reference."
  alias BurpeeTrainer.Coach.AgentPrompt

  @spec messages(BurpeeTrainer.Accounts.Scope.t(), map() | nil, String.t(), String.t(), [map()]) ::
          [map()]
  def messages(scope, source, text, prompt, extra) do
    [
      %{role: "system", content: prompt},
      %{
        role: "system",
        content:
          Jason.encode!(%{
            scope: "global",
            context: AgentPrompt.context(scope),
            rule: "Local instructions are not enduring global preferences."
          })
      },
      %{
        role: "user",
        content:
          Jason.encode!(%{
            scope: "workout_design",
            active_attempt: %{instruction: text},
            current_definition: source && source.definition_json
          })
      }
    ] ++ extra
  end
end
