defmodule BurpeeTrainer.BurpeeTypeTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.BurpeeType

  test "parse accepts supported string values" do
    assert {:ok, :six_count} = BurpeeType.parse("six_count")
    assert {:ok, :navy_seal} = BurpeeType.parse("navy_seal")
  end

  test "parse rejects unsupported values without creating atoms" do
    assert {:error, {:invalid_burpee_type, "unknown"}} = BurpeeType.parse("unknown")
  end
end
