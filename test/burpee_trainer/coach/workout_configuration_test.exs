defmodule BurpeeTrainer.Coach.WorkoutConfigurationTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.WorkoutConfiguration, as: Configuration

  test "microsecond arithmetic distinguishes whole recovery pool from spare time" do
    assert {:ok, %{work_us: 700_000_000, recovery_us: 500_000_000}} =
             Configuration.budget(140, 5, 1200)

    assert {:ok, %{work_us: 100_000_000, recovery_us: 1_100_000_000}} =
             Configuration.budget(200, 0.5, 1200)

    assert {:error, :work_exceeds_duration} = Configuration.budget(200, 7, 1200)
    assert {:ok, :unknown_pace} = Configuration.budget(140, nil, 1200)
  end
end
