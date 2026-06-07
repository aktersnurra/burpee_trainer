defmodule BurpeeTrainer.CoachTargetPlanner.NoActiveGoal do
  @moduledoc "Structured error returned when no active goal exists for a burpee type."

  defexception [:burpee_type, :message]

  @impl true
  def exception(opts) do
    burpee_type = Keyword.fetch!(opts, :burpee_type)

    %__MODULE__{
      burpee_type: burpee_type,
      message: "No active #{format_type(burpee_type)} performance goal."
    }
  end

  defp format_type(type), do: type |> Atom.to_string() |> String.replace("_", "-")
end
