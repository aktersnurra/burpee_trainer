defmodule BurpeeTrainer.Coach.Endurance do
  @moduledoc """
  How many reps a session longer than twenty minutes holds, against a twenty-minute one.
  Fatigue makes it less than in proportion: forty minutes holds one and a half times the
  reps of a good twenty-minute session (the owner's rule), not twice. The same curve,
  reps growing as minutes^log2(1.5), carries the rule on: an hour holds about 1.9 times.
  Up to twenty minutes a session counts as it is.
  """

  @twenty_minutes_sec 1_200
  @exponent :math.log2(1.5)

  @doc "The reps of a twenty-minute session that `duration_sec` holds, as a multiple."
  @spec factor(pos_integer()) :: float()
  def factor(duration_sec) when duration_sec <= @twenty_minutes_sec, do: 1.0

  # Rounded so forty minutes is exactly 1.5, not a float a hair off it.
  def factor(duration_sec),
    do: Float.round(:math.pow(duration_sec / @twenty_minutes_sec, @exponent), 6)
end
