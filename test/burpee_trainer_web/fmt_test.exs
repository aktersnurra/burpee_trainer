defmodule BurpeeTrainerWeb.FmtTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.Fmt

  test "a goal reads the same wherever it is shown" do
    goal = %{
      burpee_type: :navy_seal,
      burpee_count_target: 60,
      duration_sec_target: 1200,
      date_target: ~D[2026-12-01]
    }

    assert Fmt.goal(goal) == "Navy SEAL · 60 reps in 20 min by 2026-12-01"
  end

  test "a week reads as its dates, Monday to Sunday" do
    assert Fmt.week(~D[2026-09-07]) == "7–13 Sep"
    assert Fmt.week(~D[2026-09-28]) == "28 Sep – 4 Oct"
  end
end
