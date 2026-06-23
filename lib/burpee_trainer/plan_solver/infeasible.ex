defmodule BurpeeTrainer.PlanSolver.Infeasible do
  @moduledoc "Structured expected failure from Plan Solver v3."

  @enforce_keys [:reason, :details, :suggestions]
  defstruct @enforce_keys

  @type reason ::
          :invalid_input
          | :advanced_structure_rep_mismatch
          | :set_exceeds_max_unbroken
          | :work_alone_exceeds_duration
          | :no_pace_within_hard_bounds
          | :cannot_place_explicit_rest
          | :no_human_shaped_recovery_allocation

  @type t :: %__MODULE__{reason: reason, details: map, suggestions: [String.t()]}
end
