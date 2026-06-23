defmodule BurpeeTrainer.PlanSolver.ExplicitRest do
  @moduledoc "User-requested rest to place at a real execution boundary."

  @enforce_keys [:target_elapsed_sec, :duration_sec, :tolerance_sec]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          target_elapsed_sec: non_neg_integer,
          duration_sec: pos_integer,
          tolerance_sec: non_neg_integer
        }
end
