defmodule BurpeeTrainer.PaceModelTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PaceModel

  test "six-count level 1C fastest pace is about 6.0 seconds per rep" do
    assert_in_delta PaceModel.fastest_recommended_sec_per_rep(:six_count, :level_1c), 6.0, 0.01
  end

  test "Navy SEAL level 1C fastest pace is about 13.0 seconds per rep" do
    assert_in_delta PaceModel.fastest_recommended_sec_per_rep(:navy_seal, :level_1c), 13.0, 0.04
  end

  test "graduated equals absolute fastest standard" do
    assert PaceModel.fastest_recommended_sec_per_rep(:six_count, :graduated) == 3.7
    assert PaceModel.fastest_recommended_sec_per_rep(:navy_seal, :graduated) == 8.0
  end

  test "lower levels never get faster allowed pace than higher levels" do
    levels = [
      :level_1a,
      :level_1b,
      :level_1c,
      :level_1d,
      :level_2,
      :level_3,
      :level_4,
      :graduated
    ]

    for type <- [:six_count, :navy_seal] do
      paces = Enum.map(levels, &PaceModel.fastest_recommended_sec_per_rep(type, &1))
      assert paces == Enum.sort(paces, :desc)
    end
  end

  test "pace range uses fastest and a slower useful upper bound" do
    fastest = PaceModel.fastest_recommended_sec_per_rep(:six_count, :level_1c)

    assert {^fastest, slowest} = PaceModel.pace_range_sec_per_rep(:six_count, :level_1c)
    assert slowest > fastest
    assert PaceModel.slowest_useful_sec_per_rep(:six_count, :level_1c) == slowest
  end
end
