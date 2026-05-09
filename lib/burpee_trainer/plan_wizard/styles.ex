defmodule BurpeeTrainer.PlanWizard.Styles do
  @moduledoc """
  Pacing styles as data: each style maps `(total_reps, reps_per_set)` to a
  weight vector of length `total_reps - 1`. Slot `i` (1-indexed) is the gap
  between rep `i` and rep `i + 1`.

  The continuous solver distributes the rest budget across slots
  proportional to these weights. Adding a new style means adding a clause
  here — no other change in the solver.

      :even     — every slot weight 1.0; budget spreads uniformly into the
                  inter-rep cadence.
      :unbroken — slots at set boundaries (every `reps_per_set` reps) weight
                  1.0; intra-set slots weight 0.0; budget concentrates on
                  set breaks. The slot after the last rep does not exist —
                  there are only `total_reps - 1` slots — so the final set's
                  trailing "rest" is naturally zero.
  """

  @type style :: :even | :unbroken

  @spec weight_vector(style, pos_integer, pos_integer | nil) :: [float]
  def weight_vector(_style, total_reps, _reps_per_set) when total_reps <= 1, do: []

  def weight_vector(:even, total_reps, _reps_per_set) do
    List.duplicate(1.0, total_reps - 1)
  end

  def weight_vector(:unbroken, total_reps, reps_per_set)
      when is_integer(reps_per_set) and reps_per_set > 0 do
    for i <- 1..(total_reps - 1) do
      if rem(i, reps_per_set) == 0, do: 1.0, else: 0.0
    end
  end
end
