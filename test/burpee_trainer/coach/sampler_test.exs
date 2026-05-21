defmodule BurpeeTrainer.Coach.SamplerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.Sampler

  test "sample/2 returns a float in [0, 1]" do
    for _ <- 1..100 do
      s = Sampler.sample(2.0, 3.0)
      assert is_float(s)
      assert s >= 0.0
      assert s <= 1.0
    end
  end

  test "sample/2 with high alpha biases toward 1.0" do
    samples = for _ <- 1..200, do: Sampler.sample(100.0, 1.0)
    assert Enum.sum(samples) / 200 > 0.90
  end

  test "sample/2 with high beta biases toward 0.0" do
    samples = for _ <- 1..200, do: Sampler.sample(1.0, 100.0)
    assert Enum.sum(samples) / 200 < 0.10
  end

  test "best_arm/1 returns the index of the arm with highest sample" do
    arms = [
      %{alpha: 1.0, beta: 1.0},
      %{alpha: 100.0, beta: 1.0},
      %{alpha: 1.0, beta: 1.0}
    ]

    results = for _ <- 1..50, do: Sampler.best_arm(arms)
    assert Enum.count(results, &(&1 == 1)) > 40
  end
end
