defmodule BurpeeTrainer.PlanEditor.State do
  @moduledoc """
  Plan editor state shared by the LiveView and pure editor transitions.
  """

  alias BurpeeTrainer.PlanEditor.{Derived, Input}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  defstruct [
    :plan,
    :input,
    :level,
    :solver_error,
    :solver_solution,
    :derived,
    :form_plan,
    manual_edit?: false,
    expanded_blocks: MapSet.new(),
    open_block_menu: nil,
    selected_block_index: nil,
    locked_block_indexes: MapSet.new(),
    creator_phase: :intent
  ]

  @type t :: %__MODULE__{
          plan: WorkoutPlan.t() | nil,
          input: Input.t() | nil,
          level: atom() | nil,
          solver_error: String.t() | nil,
          solver_solution: BurpeeTrainer.PlanSolver.GeneratedPlan.t() | nil,
          derived: Derived.t() | nil,
          form_plan: WorkoutPlan.t() | nil,
          manual_edit?: boolean(),
          expanded_blocks: MapSet.t(),
          open_block_menu: String.t() | nil,
          selected_block_index: non_neg_integer() | nil,
          locked_block_indexes: MapSet.t(non_neg_integer()),
          creator_phase: :intent | :review | :editor
        }
end
