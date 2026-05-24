defmodule BurpeeTrainer.DurationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Duration

  test "parse_minutes_to_seconds accepts non-negative minute strings" do
    assert {:ok, 90} = Duration.parse_minutes_to_seconds("1.5")
    assert {:ok, 0} = Duration.parse_minutes_to_seconds("0")
  end

  test "parse_minutes_to_seconds rejects invalid values" do
    assert {:error, {:invalid_duration_min, "-1"}} = Duration.parse_minutes_to_seconds("-1")
    assert {:error, {:invalid_duration_min, "bad"}} = Duration.parse_minutes_to_seconds("bad")
  end
end
