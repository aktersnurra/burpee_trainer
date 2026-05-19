defmodule BurpeeTrainer.StreakTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Streak
  alias BurpeeTrainer.Streak.State

  defp session_on(user, date, duration_min) do
    dt = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

    {:ok, session} =
      BurpeeTrainer.Workouts.create_free_form_session(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 10,
        "duration_sec_actual" => round(duration_min * 60),
        "inserted_at" => dt
      })

    session
  end

  describe "compute/2" do
    test "returns zero streak when user has no sessions" do
      user = user_fixture()
      today = ~D[2026-05-18]
      state = Streak.compute(user, today)
      assert %State{streak_weeks: 0, current_week_minutes: 0} = state
    end

    test "counts current week minutes" do
      user = user_fixture()
      today = ~D[2026-05-18]
      session_on(user, ~D[2026-05-18], 90)
      state = Streak.compute(user, today)
      assert state.current_week_minutes >= 90
    end

    test "streak_weeks is 0 when only current week has sessions" do
      user = user_fixture()
      today = ~D[2026-05-18]
      session_on(user, today, 90)
      state = Streak.compute(user, today)
      assert state.streak_weeks == 0
    end

    test "streak_weeks counts consecutive complete prior weeks" do
      user = user_fixture()
      today = ~D[2026-05-18]
      session_on(user, ~D[2026-05-11], 90)
      session_on(user, ~D[2026-05-04], 90)
      state = Streak.compute(user, today)
      assert state.streak_weeks == 2
    end

    test "streak resets to 0 on gap week" do
      user = user_fixture()
      today = ~D[2026-05-18]
      session_on(user, ~D[2026-05-11], 90)
      session_on(user, ~D[2026-05-04], 30)
      state = Streak.compute(user, today)
      assert state.streak_weeks == 1
    end

    test "days_active_this_week includes days with sessions" do
      user = user_fixture()
      today = ~D[2026-05-18]
      session_on(user, ~D[2026-05-18], 30)
      session_on(user, ~D[2026-05-20], 30)
      state = Streak.compute(user, today)
      assert ~D[2026-05-18] in state.days_active_this_week
      assert ~D[2026-05-20] in state.days_active_this_week
      refute ~D[2026-05-19] in state.days_active_this_week
    end

    test "previous_best_weeks persists across recompute" do
      user = user_fixture()
      session_on(user, ~D[2026-04-28], 90)
      session_on(user, ~D[2026-05-04], 90)
      session_on(user, ~D[2026-05-11], 90)
      state = Streak.compute(user, ~D[2026-05-25])
      assert state.streak_weeks == 0
      assert state.previous_best_weeks == 3
    end

    test "property: naive reference matches compute/2" do
      user = user_fixture()
      today = ~D[2026-05-18]

      weeks_data = [
        {~D[2026-04-21], 90},
        {~D[2026-04-28], 50},
        {~D[2026-05-05], 90},
        {~D[2026-05-11], 90}
      ]

      for {date, min} <- weeks_data, do: session_on(user, date, min)
      state = Streak.compute(user, today)

      current_week_start = Date.beginning_of_week(today, :monday)

      # Build week_start -> total_minutes map for all prior weeks
      prior_week_minutes =
        weeks_data
        |> Enum.filter(fn {d, _} ->
          Date.compare(
            Date.beginning_of_week(d, :monday),
            current_week_start
          ) == :lt
        end)
        |> Enum.group_by(fn {d, _} -> Date.beginning_of_week(d, :monday) end)
        |> Map.new(fn {w, entries} -> {w, Enum.sum(Enum.map(entries, fn {_, m} -> m end))} end)

      # Walk backwards week-by-week from most recent prior week, same as Streak.compute/2.
      # Stop when we reach a week before any recorded session.
      earliest_week =
        prior_week_minutes
        |> Map.keys()
        |> Enum.min(Date, fn -> current_week_start end)

      expected_streak =
        Stream.iterate(Date.add(current_week_start, -7), &Date.add(&1, -7))
        |> Stream.take_while(fn w -> Date.compare(w, Date.add(earliest_week, -7)) != :lt end)
        |> Enum.reduce_while(0, fn week, acc ->
          minutes = Map.get(prior_week_minutes, week, 0)
          if minutes >= 80, do: {:cont, acc + 1}, else: {:halt, acc}
        end)

      assert state.streak_weeks == expected_streak
    end
  end
end
