defmodule BurpeeTrainer.UserTimeTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.UserTime

  test "resolve_local/3 resolves ordinary local times in Stockholm and Los Angeles" do
    assert {:ok, stockholm} =
             UserTime.resolve_local(~D[2026-08-29], ~T[00:01:00], "Europe/Stockholm")

    assert stockholm == ~U[2026-08-28 22:01:00Z] |> DateTime.shift_zone!("Europe/Stockholm")

    assert {:ok, los_angeles} =
             UserTime.resolve_local(~D[2026-08-29], ~T[00:01:00], "America/Los_Angeles")

    assert DateTime.shift_zone!(los_angeles, "Etc/UTC") == ~U[2026-08-29 07:01:00Z]
  end

  test "resolve_local/3 chooses the first valid instant after a gap and first occurrence of a fold" do
    assert {:ok, gap} =
             UserTime.resolve_local(~D[2026-03-29], ~T[02:30:00], "Europe/Stockholm")

    assert gap.hour == 3
    assert gap.minute == 0

    assert {:ok, fold} =
             UserTime.resolve_local(~D[2026-10-25], ~T[02:30:00], "Europe/Stockholm")

    assert fold.utc_offset == 3_600
    assert fold.std_offset == 3_600
  end

  test "resolve_local/3 rejects an invalid timezone" do
    assert {:error, :invalid_timezone} =
             UserTime.resolve_local(~D[2026-08-29], ~T[00:01:00], "Not/A_Timezone")
  end
end
