defmodule BurpeeTrainer.PaceModel do
  @moduledoc "Type-specific recommended pace ranges by training level."

  @type burpee_type :: :six_count | :navy_seal
  @type level ::
          :level_1a
          | :level_1b
          | :level_1c
          | :level_1d
          | :level_2
          | :level_3
          | :level_4
          | :graduated

  @absolute_fastest_sec_per_rep %{
    six_count: 3.70,
    navy_seal: 8.00
  }

  @level_multiplier %{
    level_1a: 2.15,
    level_1b: 1.90,
    level_1c: 1.62,
    level_1d: 1.49,
    level_2: 1.35,
    level_3: 1.22,
    level_4: 1.08,
    graduated: 1.00
  }

  @spec fastest_recommended_sec_per_rep(burpee_type(), level()) :: float()
  def fastest_recommended_sec_per_rep(burpee_type, level) do
    Map.fetch!(@absolute_fastest_sec_per_rep, burpee_type) * Map.fetch!(@level_multiplier, level)
  end

  @spec slowest_useful_sec_per_rep(burpee_type(), level()) :: float()
  def slowest_useful_sec_per_rep(burpee_type, level) do
    fastest_recommended_sec_per_rep(burpee_type, level) * 1.45
  end

  @spec pace_range_sec_per_rep(burpee_type(), level()) :: {float(), float()}
  def pace_range_sec_per_rep(burpee_type, level) do
    fastest = fastest_recommended_sec_per_rep(burpee_type, level)
    {fastest, fastest * 1.45}
  end
end
