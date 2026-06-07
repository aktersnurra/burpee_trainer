defmodule BurpeeTrainer.CatchUpPlanner.Metadata do
  @moduledoc "Debug metadata for catch-up candidate selection."

  defstruct solver_version: "catch-up-v1",
            selected_candidate_count: 0,
            rejected_candidate_count: 0,
            objective_value: 0.0,
            objective_breakdown: %{}
end
