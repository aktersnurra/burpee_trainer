defmodule BurpeeTrainer.Coach.Sampler do
  @moduledoc """
  Thompson sampling for Beta-distributed bandit arms.

  Uses the Johnk method to sample from Beta(alpha, beta):
  draw X ~ Gamma(alpha, 1) and Y ~ Gamma(beta, 1) via Erlang method,
  then return X / (X + Y).
  """

  @spec sample(float, float) :: float
  def sample(alpha, beta) when alpha > 0 and beta > 0 do
    x = gamma_sample(alpha)
    y = gamma_sample(beta)
    x / (x + y)
  end

  @spec best_arm([map]) :: non_neg_integer
  def best_arm(arms) do
    arms
    |> Enum.with_index()
    |> Enum.max_by(fn {arm, _i} -> sample(arm.alpha, arm.beta) end)
    |> elem(1)
  end

  # Gamma(k, 1) via Erlang method: sum of k exponential samples.
  # alpha/beta start at 1.0 and increment by 1.0, so k is always
  # an integer in practice.
  defp gamma_sample(k) do
    n = max(1, round(k))

    Enum.reduce(1..n, 0.0, fn _, acc ->
      acc - :math.log(max(:rand.uniform(), 1.0e-15))
    end)
  end
end
