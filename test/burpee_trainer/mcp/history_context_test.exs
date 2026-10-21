defmodule BurpeeTrainer.Mcp.HistoryContextTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Mcp.{HistoryContext, Sessions}

  test "an exclusive requested end remains exclusive when it equals as_of" do
    user = %{timezone: "Etc/UTC"}
    args = %{"to" => "2026-03-29"}
    {:ok, filters} = Sessions.filters(args, user, ~U[2026-03-30 00:00:00Z])
    context = HistoryContext.build(args, user, filters, 0, 0)
    refute context["cutoff_inclusive"]
  end

  test "fall DST complete day versus a cutoff within the same local day" do
    user = %{timezone: "Europe/Stockholm"}
    args = %{"from" => "2026-10-25", "to" => "2026-10-25"}
    {:ok, filters} = Sessions.filters(args, user, ~U[2026-10-26 12:00:00Z])
    context = HistoryContext.build(args, user, filters, 0, 0)
    assert context["from_utc_inclusive"] == "2026-10-24T22:00:00Z"
    assert context["to_utc_exclusive"] == "2026-10-25T23:00:00Z"
    refute HistoryContext.partial?(~D[2026-10-25], ~D[2026-10-25], filters, user.timezone)

    assert HistoryContext.partial?(
             ~D[2026-10-25],
             ~D[2026-10-25],
             %{filters | as_of: ~U[2026-10-25 22:59:59Z]},
             user.timezone
           )
  end
end
