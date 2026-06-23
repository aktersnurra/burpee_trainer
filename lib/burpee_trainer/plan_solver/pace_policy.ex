defmodule BurpeeTrainer.PlanSolver.PacePolicy do
  @moduledoc """
  Hard and preferred movement pace bounds for Plan Solver v3.

  Seconds-per-rep values are directional: lower is faster, higher is slower.
  Hard bounds are never relaxed. Preferred bounds are scoring input.
  """

  @enforce_keys [
    :hard_fastest_sec_per_rep,
    :preferred_fast_sec_per_rep,
    :preferred_slow_sec_per_rep,
    :hard_slowest_sec_per_rep
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hard_fastest_sec_per_rep: float,
          preferred_fast_sec_per_rep: float,
          preferred_slow_sec_per_rep: float,
          hard_slowest_sec_per_rep: float
        }

  @spec for(:six_count | :navy_seal) :: t()
  def for(:six_count) do
    new!(3.7, 4.8, 5.8, 7.0)
  end

  def for(:navy_seal) do
    new!(8.0, 9.0, 11.0, 13.0)
  end

  defp new!(hard_fastest, preferred_fast, preferred_slow, hard_slowest) do
    true = hard_fastest <= preferred_fast
    true = preferred_fast <= preferred_slow
    true = preferred_slow <= hard_slowest

    %__MODULE__{
      hard_fastest_sec_per_rep: hard_fastest,
      preferred_fast_sec_per_rep: preferred_fast,
      preferred_slow_sec_per_rep: preferred_slow,
      hard_slowest_sec_per_rep: hard_slowest
    }
  end
end
