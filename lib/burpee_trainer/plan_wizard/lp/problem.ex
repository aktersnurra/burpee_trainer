defmodule BurpeeTrainer.PlanWizard.Lp.Problem do
  @moduledoc """
  Canonical representation of a linear/MILP problem ready for serialization.

  Variables are referenced by string name. Coefficients are stored in
  sparse form: each constraint and the objective hold a list of
  `{var_name, coefficient}` pairs.

  Variable name conventions used by `BurpeeTrainer.PlanWizard.Lp`:

    * `r_<i>`     — rest at slot i (continuous, ≥ 0)
    * `e_<i>`     — absolute deviation of r_i from ideal (continuous, ≥ 0)
    * `x_<k>_<i>` — binary assignment, reservation k → slot i
    * `y_<k>_<i>` — bilinear linearization, x_{k,i} * slot_end_time[i]
    * `d_<k>`     — placement error for reservation k (continuous, ≥ 0)
  """

  @type sense :: :minimize | :maximize
  @type comparator :: :eq | :leq | :geq
  @type term_ :: {String.t(), float}
  @type constraint :: %{
          name: String.t(),
          terms: [term_],
          comparator: comparator,
          rhs: float
        }
  @type variable :: %{
          name: String.t(),
          type: :continuous | :binary,
          lower: float | :neg_inf,
          upper: float | :pos_inf
        }

  @enforce_keys [:objective_sense, :objective_terms, :variables, :constraints]
  defstruct [:objective_sense, :objective_terms, :variables, :constraints]

  @type t :: %__MODULE__{
          objective_sense: sense,
          objective_terms: [term_],
          variables: [variable],
          constraints: [constraint]
        }
end
