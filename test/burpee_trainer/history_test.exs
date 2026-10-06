defmodule BurpeeTrainer.HistoryTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainer.History

  test "local four-week window and actual density retain session identity" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "America/Los_Angeles")
    now = ~U[2025-09-24 12:00:00Z]

    rows =
      for {at, seconds} <- [
            {~U[2025-09-01 06:59:59Z], 600},
            {~U[2025-09-01 07:00:00Z], 600},
            {~U[2025-09-22 07:00:00Z], 0},
            {~U[2025-09-24 12:00:01Z], 600}
          ] do
        Repo.insert!(%WorkoutSession{
          user_id: user.id,
          state: :completed,
          source_kind: :manual,
          burpee_type: :six_count,
          capture_mode: :logged,
          completed_at: at,
          burpee_count_actual: 30,
          duration_sec_actual: seconds,
          burpee_count_planned: 100,
          duration_sec_planned: 1_200
        })
      end

    [outside, included, zero, future] = rows
    assert {:ok, filtered} = History.filter_sessions(rows, user, now, "four_weeks")
    assert Enum.map(filtered, & &1.id) == [included.id, zero.id]

    assert [%{id: id, actual_reps: 30, actual_duration_sec: 600, density: 60}] =
             History.points(filtered)

    assert id == included.id
    assert {:ok, [^zero]} = History.filter_sessions(rows, user, now, "week")
    assert {:ok, all} = History.filter_sessions(rows, user, now, "all")
    assert outside in all
    refute future in all
  end

  test "pages preserve tied timestamp order exactly once and exclude foreign and started rows" do
    user = user_fixture()
    now = ~U[2025-09-24 12:00:00Z]
    for _ <- 1..12, do: insert_session(user, now)
    foreign = insert_session(user_fixture(), now)
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    assert {:ok, first, cursor, true} = History.page(Scope.for_user(user), now, "all")
    assert length(first) == 5
    assert cursor == {List.last(first).completed_at, List.last(first).id}
    assert {:ok, second, cursor, true} = History.page(Scope.for_user(user), now, "all", cursor)
    assert length(second) == 5
    assert cursor == {List.last(second).completed_at, List.last(second).id}
    assert {:ok, third, cursor, false} = History.page(Scope.for_user(user), now, "all", cursor)
    assert length(third) == 2
    assert {:ok, [], ^cursor, false} = History.page(Scope.for_user(user), now, "all", cursor)

    ids = Enum.map(first ++ second ++ third, & &1.id)
    assert ids == Enum.map(Workouts.list_sessions(Scope.for_user(user)), & &1.id)
    assert length(Enum.uniq(ids)) == 12
    refute foreign.id in ids
    refute started.id in ids

    assert {:ok, [], _, false} =
             History.page(Scope.for_user(user), ~U[2025-10-06 12:00:00Z], "week")
  end

  test "page scans past future rows and stops after the last matching period row" do
    user = user_fixture()
    now = ~U[2025-09-24 12:00:00Z]
    for _ <- 1..6, do: insert_session(user, DateTime.add(now, 1, :second))
    matching = for _ <- 1..7, do: insert_session(user, now)
    for _ <- 1..6, do: insert_session(user, ~U[2025-08-01 00:00:00Z])

    assert {:ok, first, cursor, true} = History.page(Scope.for_user(user), now, "week")
    assert length(first) == 5
    assert {:ok, last, _, false} = History.page(Scope.for_user(user), now, "week", cursor)
    assert length(last) == 2
    assert Enum.map(first ++ last, & &1.id) == Enum.map(Enum.reverse(matching), & &1.id)
  end

  test "invalid timezone and cursor return errors without inventing a period" do
    user = user_fixture()
    now = ~U[2025-09-24 12:00:00Z]
    invalid = %{user | timezone: "Invalid/Zone"}

    for period <- ["week", "four_weeks", "all"] do
      assert {:error, :invalid_timezone} = History.filter_sessions([], invalid, now, period)
      assert {:error, :invalid_timezone} = History.page(Scope.for_user(invalid), now, period)
    end

    assert {:error, :invalid_timezone} = History.results(Scope.for_user(invalid), now)
    assert {:error, :invalid_cursor} = History.page(Scope.for_user(user), now, "all", "invalid")
    assert {:ok, [], nil, false} = History.page(Scope.for_user(user), now, "all")
    assert {:ok, %{today: [], week: []}} = History.results(Scope.for_user(user), now)
  end

  test "week and four weeks include local Monday across year and DST changes; all has no lower bound" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "America/Los_Angeles")

    for {now, week_start, four_week_start} <- [
          {~U[2025-01-01 12:00:00Z], ~U[2024-12-30 08:00:00Z], ~U[2024-12-09 08:00:00Z]},
          {~U[2025-03-12 12:00:00Z], ~U[2025-03-10 07:00:00Z], ~U[2025-02-17 08:00:00Z]},
          {~U[2025-11-05 12:00:00Z], ~U[2025-11-03 08:00:00Z], ~U[2025-10-13 07:00:00Z]}
        ],
        {period, lower} <- [{"week", week_start}, {"four_weeks", four_week_start}] do
      before = session(user, DateTime.add(lower, -1, :second))
      boundary = session(user, lower)
      current = session(user, now)
      future = session(user, DateTime.add(now, 1, :second))
      rows = [before, boundary, current, future]

      assert {:ok, [^boundary, ^current]} = History.filter_sessions(rows, user, now, period)

      assert {:ok, [^before, ^boundary, ^current]} =
               History.filter_sessions(rows, user, now, "all")
    end
  end

  test "missing and zero actual measurements stay inspectable without synthetic density" do
    user = user_fixture()
    now = ~U[2025-09-24 12:00:00Z]

    # Persisted completions require nonnil actuals; exercise incomplete input as pure structs.
    rows =
      for attrs <- [
            [duration_sec_actual: nil],
            [duration_sec_actual: 0],
            [burpee_count_actual: nil],
            [burpee_count_actual: 0]
          ] do
        session(user, now, attrs)
      end

    for period <- ["week", "four_weeks", "all"] do
      assert {:ok, ^rows} = History.filter_sessions(rows, user, now, period)
    end

    assert History.points(rows) == []
    assert History.points([]) == []
    assert {:ok, []} = History.filter_sessions([session(user, nil)], user, now, "all")
  end

  test "density uses Series rounding and chronological timestamp then identity ordering" do
    user = user_fixture()
    now = ~U[2025-09-24 12:00:00Z]
    first = insert_session(user, now, burpee_count_actual: 31, duration_sec_actual: 700)
    second = insert_session(user, now, burpee_type: :navy_seal)
    earlier = insert_session(user, DateTime.add(now, -1, :second))

    assert [early_point, first_point, second_point] = History.points([second, first, earlier])

    assert Enum.map([early_point, first_point, second_point], & &1.id) == [
             earlier.id,
             first.id,
             second.id
           ]

    assert first_point == %{
             id: first.id,
             completed_at: now,
             actual_reps: 31,
             actual_duration_sec: 700,
             density: 53
           }

    assert second_point.density == 60
  end

  test "authoritative warmup is an actual today result and History row but earns no Policy credit" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "America/Los_Angeles")
    now = ~U[2025-09-24 12:00:00Z]
    warmup = insert_session(user, now, tags: "warmup", display_name_snapshot: "Saved warmup")

    assert {:ok, %{today: [^warmup], week: [^warmup]}} =
             History.results(Scope.for_user(user), now)

    assert {:ok, %{completed_sec: 0}} = Policy.required_slot(Scope.for_user(user), now)
    assert {:ok, [row], _, false} = History.page(Scope.for_user(user), now, "week")
    assert row.id == warmup.id
    assert row.tags == "warmup"
    assert row.display_name_snapshot == "Saved warmup"
    assert row.burpee_count_actual == 30
    assert row.burpee_count_planned == 100
    assert [%{density: 60}] = History.points([row])
  end

  test "results select owned authoritative today and week facts by local completion date" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "America/Los_Angeles")
    now = ~U[2025-09-24 12:00:00Z]
    insert_session(user_fixture(), now)
    insert_session(user, DateTime.add(now, 1, :second))
    insert_session(user, ~U[2025-09-22 06:59:59Z])
    week_start = insert_session(user, ~U[2025-09-22 07:00:00Z])
    yesterday = insert_session(user, ~U[2025-09-24 06:59:59Z])
    today = insert_session(user, ~U[2025-09-24 07:00:00Z], duration_sec_actual: 0)
    current = insert_session(user, now)

    assert {:ok, %{today: [^current, ^today], week: [^current, ^today, ^yesterday, ^week_start]}} =
             History.results(Scope.for_user(user), now)
  end

  test "summary derives display totals and latest existing density without persistence" do
    user = user_fixture()

    sessions = [
      session(user, ~U[2026-09-08 08:00:00Z], burpee_count_actual: 20, duration_sec_actual: 240),
      session(user, ~U[2026-09-09 08:00:00Z], burpee_count_actual: 30, duration_sec_actual: 360),
      session(user, ~U[2026-09-10 08:00:00Z], burpee_count_actual: nil, duration_sec_actual: nil)
    ]

    assert History.summary(sessions) == %{
             sessions: 3,
             total_reps: 50,
             active_time_sec: 600,
             latest_density: 100
           }
  end

  test "summary returns honest zero and unavailable density" do
    assert History.summary([]) == %{
             sessions: 0,
             total_reps: 0,
             active_time_sec: 0,
             latest_density: nil
           }
  end

  test "daily drilldown credits only real local authoritative minutes" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "America/Los_Angeles")
    now = ~U[2026-09-23 12:00:00Z]
    week = ~D[2026-09-21]

    sessions = [
      session(user, ~U[2026-09-21 06:59:59Z], duration_sec_actual: 600),
      session(user, ~U[2026-09-21 07:00:00Z], duration_sec_actual: 1_200),
      session(user, ~U[2026-09-22 07:00:00Z], duration_sec_actual: 300),
      session(user, ~U[2026-09-22 08:00:00Z], tags: "warmup", duration_sec_actual: 4_800),
      session(user, DateTime.add(now, 10, :second), duration_sec_actual: 4_800)
    ]

    assert {:ok, days} = History.week_days(sessions, user, now, week)
    assert Enum.map(days, & &1.minutes) == [20, 5, 0, 0, 0, 0, 0]
    assert Enum.map(days, & &1.date) == Enum.map(0..6, &Date.add(week, &1))
    assert {:ok, weeks} = History.weeks(sessions, user, now, "twelve_weeks")
    assert List.last(weeks).minutes == 25
  end

  test "daily drilldown preserves sub-minute credited seconds across days" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    now = ~U[2026-09-23 12:00:00Z]
    week = ~D[2026-09-21]

    sessions = [
      session(user, ~U[2026-09-21 12:00:00Z], duration_sec_actual: 59),
      session(user, ~U[2026-09-22 12:00:00Z], duration_sec_actual: 59)
    ]

    assert {:ok, days} = History.week_days(sessions, user, now, week)
    assert Enum.map(days, & &1.seconds) == [59, 59, 0, 0, 0, 0, 0]
    assert Enum.map(days, & &1.minutes) == [0, 0, 0, 0, 0, 0, 0]
    assert {:ok, weeks} = History.weeks(sessions, user, now, "twelve_weeks")
    assert List.last(weeks).minutes == 1
  end

  test "weekly grid credits authoritative minutes and excludes open week from streak" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    now = ~U[2026-09-23 12:00:00Z]

    sessions = [
      session(user, ~U[2026-09-07 12:00:00Z], duration_sec_actual: 4_800),
      session(user, ~U[2026-09-14 12:00:00Z], duration_sec_actual: 4_800),
      session(user, ~U[2026-09-21 12:00:00Z], duration_sec_actual: 5_000),
      session(user, ~U[2026-09-21 13:00:00Z], tags: "warmup", duration_sec_actual: 2_000)
    ]

    assert {:ok, weeks} = History.weeks(sessions, user, now, "twelve_weeks")
    assert length(weeks) == 12
    assert Enum.map(Enum.take(weeks, -3), & &1.minutes) == [80, 80, 83]
    assert History.streak(weeks) == 2
    assert List.last(weeks).open?
    assert {:ok, year} = History.weeks(sessions, user, now, "year")
    assert length(year) >= 52
  end

  defp insert_session(user, at, attrs \\ []) do
    user |> session(at, attrs) |> Repo.insert!()
  end

  defp session(user, at, attrs \\ []) do
    struct!(
      %WorkoutSession{
        user_id: user.id,
        state: :completed,
        source_kind: :manual,
        burpee_type: :six_count,
        capture_mode: :logged,
        completed_at: at,
        burpee_count_actual: 30,
        duration_sec_actual: 600,
        burpee_count_planned: 100,
        duration_sec_planned: 1_200
      },
      attrs
    )
  end
end
