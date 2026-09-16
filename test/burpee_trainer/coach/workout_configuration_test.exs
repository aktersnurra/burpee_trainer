defmodule BurpeeTrainer.Coach.WorkoutConfigurationTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.WorkoutConfiguration, as: Configuration

  test "patterns expand in order, with bounded positive groups" do
    assert {:ok, sets} = Configuration.parse_sets("5x8, 5x7, 5x(7,6)")

    assert sets ==
             List.duplicate(8, 5) ++
               List.duplicate(7, 5) ++ List.flatten(List.duplicate([7, 6], 5))

    assert length(sets) == 20
    assert Enum.sum(sets) == 140
    assert {:ok, forty} = Configuration.parse_sets("20×(5,5)")
    assert length(forty) == 40

    for text <- ["0x8", "5x0", "5x(7,)", "5x(7,(6))", "1000000x1", "5x8 junk", "5x8,"] do
      assert {:error, _} = Configuration.parse_sets(text)
    end
  end

  test "rest durations describe total pauses at absolute starts" do
    assert {:ok, [%{"start_sec" => 660, "duration_sec" => 60}]} =
             Configuration.parse_rests("60s at 11:00")

    assert {:ok, [%{"start_sec" => 660, "duration_sec" => 60}]} =
             Configuration.parse_rests("11:00 / 60")

    assert {:error, _} = Configuration.parse_rests("60s someday")
  end

  test "microsecond arithmetic distinguishes whole recovery pool from spare time" do
    assert {:ok, %{work_us: 700_000_000, recovery_us: 500_000_000}} =
             Configuration.budget(140, 5, 1200)

    assert {:ok, %{work_us: 100_000_000, recovery_us: 1_100_000_000}} =
             Configuration.budget(200, 0.5, 1200)

    assert {:error, :work_exceeds_duration} = Configuration.budget(200, 7, 1200)
    assert {:ok, :unknown_pace} = Configuration.budget(140, nil, 1200)
  end
end
