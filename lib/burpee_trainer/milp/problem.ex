defmodule BurpeeTrainer.Milp.Problem do
  @moduledoc """
  Canonical representation of a linear/MILP problem ready for serialization.

  Variables are referenced by string name. Coefficients are stored in
  sparse form: each constraint and the objective hold a list of
  `{var_name, coefficient}` pairs.
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
