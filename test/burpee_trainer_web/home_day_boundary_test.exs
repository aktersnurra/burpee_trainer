defmodule BurpeeTrainerWeb.HomeDayBoundaryTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.HomeDayBoundary

  test "next local midnight uses 23/25-hour DST days" do
    user = %{timezone: "America/Los_Angeles"}

    assert {:ok, 23 * 60 * 60 * 1000} ==
             HomeDayBoundary.delay_ms(user, ~U[2025-03-09 08:00:00Z])

    assert {:ok, 25 * 60 * 60 * 1000} ==
             HomeDayBoundary.delay_ms(user, ~U[2025-11-02 07:00:00Z])

    assert {:error, :invalid_timezone} =
             HomeDayBoundary.delay_ms(%{timezone: "Invalid/Zone"}, ~U[2025-09-01 12:00:00Z])
  end

  test "year rollover and the final millisecond stay positive" do
    user = %{timezone: "Etc/UTC"}
    assert {:ok, 1} = HomeDayBoundary.delay_ms(user, ~U[2025-12-31 23:59:59.999Z])
    assert {:ok, 86_400_000} = HomeDayBoundary.delay_ms(user, ~U[2026-01-01 00:00:00Z])
  end
end
