defmodule BurpeeTrainer.PlanEditor.State do
  @moduledoc """
  Plan editor state shared by the LiveView and pure editor transitions.
  """

  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanEditor.Derived
  alias BurpeeTrainer.PlanEditor.Structure
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.Workouts.WorkoutPlan

  defstruct [
    :plan,
    :input,
    :level,
    :solver_error,
    :solver_solution,
    :derived,
    :form_plan,
    :structure,
    manual_edit?: false,
    expanded_blocks: MapSet.new(),
    open_block_menu: nil
  ]

  @type t :: %__MODULE__{
          plan: WorkoutPlan.t() | nil,
          input: PlanEditor.input() | nil,
          level: atom() | nil,
          solver_error: String.t() | nil,
          solver_solution: PlanSolver.Solution.t() | nil,
          derived: Derived.t() | nil,
          form_plan: WorkoutPlan.t() | nil,
          structure: Structure.t() | nil,
          manual_edit?: boolean(),
          expanded_blocks: MapSet.t(),
          open_block_menu: String.t() | nil
        }
end
