defmodule BurpeeTrainer.Mcp.SessionsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Mcp.Sessions

  @user %{timezone: "Etc/UTC"}
  @now ~U[2026-10-24 12:00:00Z]

  test "missing, one-sided, and equal bounds are accepted" do
    for args <- [
          %{},
          %{"min_reps" => 0},
          %{"max_reps" => 10},
          %{"min_duration_sec" => 0},
          %{"max_duration_sec" => 1200},
          %{"from" => "2026-10-23"},
          %{"to" => "2026-10-23"},
          %{"min_reps" => 10, "max_reps" => 10},
          %{"min_duration_sec" => 1200, "max_duration_sec" => 1200},
          %{"from" => "2026-10-23", "to" => "2026-10-23"}
        ] do
      assert {:ok, _} = Sessions.filters(args, @user, @now)
    end
  end

  test "each inverted range is rejected even when preceding bounds are valid" do
    for {args, message} <- [
          {%{"min_duration_sec" => 1201, "max_duration_sec" => 1200},
           "min_duration_sec must not exceed max_duration_sec"},
          {%{
             "min_duration_sec" => 1200,
             "max_duration_sec" => 1200,
             "min_reps" => 11,
             "max_reps" => 10
           }, "min_reps must not exceed max_reps"},
          {%{
             "min_duration_sec" => 1200,
             "max_duration_sec" => 1200,
             "min_reps" => 10,
             "max_reps" => 10,
             "from" => "2026-10-24",
             "to" => "2026-10-23"
           }, "from must not be after to"}
        ] do
      assert {:error, ^message} = Sessions.filters(args, @user, @now)
    end
  end

  test "duration errors take precedence over rep and date errors" do
    args = %{
      "min_duration_sec" => 1201,
      "max_duration_sec" => 1200,
      "min_reps" => 11,
      "max_reps" => 10,
      "from" => "2026-10-24",
      "to" => "2026-10-23"
    }

    assert {:error, "min_duration_sec must not exceed max_duration_sec"} =
             Sessions.filters(args, @user, @now)
  end
end
