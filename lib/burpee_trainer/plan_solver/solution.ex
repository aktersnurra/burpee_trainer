defmodule BurpeeTrainer.PlanSolver.Solution do
  @moduledoc """
  Clean output of `BurpeeTrainer.PlanSolver.solve/1`.

  A solution is the solved domain artifact: prescription plus executable events.
  It intentionally does not contain the derived `%WorkoutPlan{}` projection or
  display-summary fields. Call `PlanSolver.generate_plan/1` when a caller needs
  the editor/storage projection.
  """

  alias BurpeeTrainer.PlanSolver.{Execution, Prescription}

  @enforce_keys [:metadata, :execution, :prescription]
  defstruct @enforce_keys

  @type metadata :: map

  @type t :: %__MODULE__{
          metadata: metadata,
          execution: Execution.t(),
          prescription: Prescription.t()
        }

  @spec from(Prescription.t(), Execution.t()) :: t()
  def from(%Prescription{} = prescription, execution) when is_list(execution) do
    %__MODULE__{
      metadata: prescription.metadata,
      execution: execution,
      prescription: prescription
    }
  end
end
