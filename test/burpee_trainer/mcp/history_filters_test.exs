defmodule BurpeeTrainer.Mcp.HistoryFiltersTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Mcp.Sessions
  alias BurpeeTrainer.Workouts

  @now ~U[2026-10-20 12:00:00Z]

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  test "duration bounds are inclusive actual seconds, never planned", %{user: user, scope: scope} do
    rows =
      for duration <- [0, 59, 60, 120, 121],
          do:
            Repo.insert!(%Workouts.WorkoutSession{
              user_id: user.id,
              state: :completed,
              source_kind: :manual,
              capture_mode: :logged,
              burpee_type: :six_count,
              burpee_count_actual: 25,
              duration_sec_actual: duration,
              duration_sec_planned: 90,
              completed_at: @now
            })

    assert ids(scope, %{"min_duration_sec" => 60, "max_duration_sec" => 120}) ==
             Enum.map(Enum.slice(rows, 2, 2) |> Enum.reverse(), & &1.id)

    assert ids(scope, %{"min_duration_sec" => 0, "max_duration_sec" => 0}) == [
             Enum.at(rows, 0).id
           ]

    assert ids(scope, %{"max_duration_sec" => 59}) == [Enum.at(rows, 1).id, Enum.at(rows, 0).id]
    assert ids(scope, %{}) == Enum.map(Enum.reverse(rows), & &1.id)
  end

  test "canonical warmup matches only the exact tag and exclusion keeps NULL", %{
    user: user,
    scope: scope
  } do
    rows =
      for tags <- [nil, "warmup", "warmup,heat", " warmup ", "prewarmup", "heat"],
          do: session(user, %{tags: tags})

    all = Enum.map(Enum.reverse(rows), & &1.id)
    warmup = Enum.at(rows, 1).id
    assert ids(scope, %{}) == all
    assert ids(scope, %{"warmup" => "include"}) == all
    assert ids(scope, %{"warmup" => "only"}) == [warmup]
    assert ids(scope, %{"warmup" => "exclude"}) == all -- [warmup]
  end

  test "invalid types, enum and reversed bounds are rejected", %{user: user} do
    for key <- ~w[min_duration_sec max_duration_sec], value <- [-1, 1.5, "60", nil, true] do
      assert {:error, _} = Sessions.filters(%{key => value}, user, @now)
    end

    for value <- ["sometimes", :only, nil, 1] do
      assert {:error, _} = Sessions.filters(%{"warmup" => value}, user, @now)
    end

    assert {:error, _} =
             Sessions.filters(%{"min_duration_sec" => 61, "max_duration_sec" => 60}, user, @now)

    assert {:error, _} =
             Sessions.filters(%{"from" => "2026-03-30", "to" => "2026-03-29"}, user, @now)

    assert {:error, _} = Sessions.filters(%{"min_reps" => 11, "max_reps" => 10}, user, @now)
  end

  test "local inclusive dates span DST days without admitting neighboring dates", %{user: user} do
    user = %{user | timezone: "Europe/Stockholm"}
    scope = Scope.for_user(user)

    for {date, start, finish, hours} <- [
          {"2026-03-29", ~U[2026-03-28 23:00:00Z], ~U[2026-03-29 22:00:00Z], 23},
          {"2026-10-25", ~U[2026-10-24 22:00:00Z], ~U[2026-10-25 23:00:00Z], 25}
        ] do
      now = ~U[2026-11-01 12:00:00Z]
      session(user, %{completed_at: DateTime.add(start, -1)})
      first = session(user, %{completed_at: start})
      last = session(user, %{completed_at: DateTime.add(finish, -1)})
      session(user, %{completed_at: finish})
      assert {:ok, filters} = Sessions.filters(%{"from" => date, "to" => date}, user, now)
      assert DateTime.diff(filters.before, filters.from) == hours * 3600
      assert {rows, false} = Workouts.list_sessions_page(scope, 100, filters: filters)
      assert Enum.map(rows, & &1.id) == [last.id, first.id]
    end
  end

  test "trusted cutoff excludes future completions even with a future to date", %{
    user: user,
    scope: scope
  } do
    at = session(user, %{})
    session(user, %{completed_at: DateTime.add(@now, 1)})
    assert ids(scope, %{}) == [at.id]
    assert ids(scope, %{"to" => "2027-01-01"}) == [at.id]
    assert ids(scope, %{"from" => "2027-01-01"}) == []
  end

  test "composed filters preserve ownership and tied-timestamp cursor order", %{
    user: user,
    scope: scope
  } do
    session(user_fixture(), %{})
    session(user, %{tags: "warmup"})
    session(user, %{duration_sec_actual: 10})
    made = for _ <- 1..3, do: session(user, %{})

    assert {:ok, filters} =
             Sessions.filters(%{"warmup" => "exclude", "min_duration_sec" => 60}, user, @now)

    assert {[first, second], true} = Workouts.list_sessions_page(scope, 2, filters: filters)

    {:ok, cursor} =
      Sessions.decode_cursor(Sessions.encode_cursor({second.completed_at, second.id}))

    assert {[third], false} =
             Workouts.list_sessions_page(scope, 2, filters: filters, before: cursor)

    assert Enum.map([first, second, third], & &1.id) == Enum.map(Enum.reverse(made), & &1.id)
  end

  defp session(user, attrs),
    do: free_form_session_fixture(user, Map.put_new(attrs, :completed_at, @now))

  defp ids(scope, args) do
    assert {:ok, filters} = Sessions.filters(args, scope.user, @now)
    {rows, false} = Workouts.list_sessions_page(scope, 100, filters: filters)
    Enum.map(rows, & &1.id)
  end
end
