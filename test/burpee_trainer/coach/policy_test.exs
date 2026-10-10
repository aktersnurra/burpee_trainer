defmodule BurpeeTrainer.Coach.PolicyTest do
  use BurpeeTrainer.DataCase, async: false
  use ExUnitProperties

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{PlanCompiler, Repo}

  test "uses the exact 4,800 second target and Monday begins a clean local week" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")

    complete(user, ~U[2025-08-31 23:00:00Z], 4_800)

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2025-09-01 08:00:00Z])
    assert slot.weekly_target_sec == 4_800
    assert slot.completed_sec == 0
    assert slot.remaining_sec == 4_800
    assert slot.local_date == ~D[2025-09-01]
  end

  test "home priority is done today, then week complete, then workout needed" do
    user = user_fixture() |> provision_timezone("Etc/UTC")
    monday = ~U[2025-09-01 12:00:00Z]

    assert {:ok, %{home_state: :workout_needed}} =
             Policy.required_slot(Scope.for_user(user), monday)

    complete(user, monday, 1_200)
    assert {:ok, %{home_state: :done_today}} = Policy.required_slot(Scope.for_user(user), monday)

    complete(user, ~U[2025-09-02 12:00:00Z], 3_600)

    assert {:ok, %{home_state: :week_complete}} =
             Policy.required_slot(Scope.for_user(user), ~U[2025-09-03 12:00:00Z])
  end

  test "today wins at target, next day completes week, Monday has no debt" do
    user = user_fixture() |> provision_timezone("Etc/UTC")
    complete(user, ~U[2025-09-01 12:00:00Z], 1_200)

    assert {:ok, %{home_state: :done_today, completed_sec: 1_200}} =
             Policy.required_slot(Scope.for_user(user), ~U[2025-09-01 12:00:00Z])

    complete(user, ~U[2025-09-02 12:00:00Z], 3_600)

    assert {:ok, %{home_state: :done_today, completed_sec: 4_800, remaining_sec: 0}} =
             Policy.required_slot(Scope.for_user(user), ~U[2025-09-02 12:00:00Z])

    assert {:ok, %{home_state: :week_complete, completed_sec: 4_800}} =
             Policy.required_slot(Scope.for_user(user), ~U[2025-09-03 12:00:00Z])

    assert {:ok, %{home_state: :workout_needed, completed_sec: 0, remaining_sec: 4_800}} =
             Policy.required_slot(Scope.for_user(user), ~U[2025-09-08 00:00:00Z])
  end

  test "weekend catch-up covers the full remainder at 2,400 seconds and is never exploration" do
    user = user_fixture() |> provision_timezone("Etc/UTC")
    complete(user, ~U[2025-09-01 12:00:00Z], 2_400)

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2025-09-06 12:00:00Z])
    assert slot.duration_sec == 2_400
    assert slot.remaining_sec == 2_400
    assert slot.strategy == :catch_up
    refute slot.exploration_allowed?
  end

  test "PB uses same-type prescribed 20-minute completed sessions in the trailing six weeks" do
    user = user_fixture() |> provision_timezone("Etc/UTC")
    now = ~U[2025-09-06 12:00:00Z]

    complete(user, DateTime.add(now, -41 * 86_400, :second), 1_200,
      source_kind: :plan,
      planned: 1_200,
      actual_reps: 100,
      type: :six_count
    )

    complete(user, DateTime.add(now, -10 * 86_400, :second), 1_200,
      source_kind: :plan,
      planned: 1_199,
      actual_reps: 200,
      type: :six_count
    )

    complete(user, DateTime.add(now, -11 * 86_400, :second), 1_200,
      source_kind: :manual,
      planned: 1_200,
      actual_reps: 300,
      type: :six_count
    )

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)
    assert slot.personal_best.reps == 100
    assert slot.personal_best.completed_at == DateTime.add(now, -41 * 86_400, :second)
  end

  test "persisted immutable snapshot transitions enforce one exploration in three workouts" do
    user = user_fixture() |> provision_timezone("Etc/UTC")

    baseline = structured_definition("Baseline", 100)
    recovery_exploration = structured_definition("Recovery exploration", 200)

    first =
      complete(user, ~U[2025-08-28 09:00:00Z], 1_200,
        source_kind: :plan,
        definition: baseline
      )

    second =
      complete(user, ~U[2025-08-29 09:00:00Z], 1_200,
        source_kind: :plan,
        definition: recovery_exploration
      )

    complete(user, ~U[2025-08-30 09:00:00Z], 1_200)

    assert is_map(first.program_snapshot)
    assert is_map(second.program_snapshot)

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2025-09-01 12:00:00Z])
    refute slot.exploration_allowed?
  end

  test "manual and unfingerprintable completions count in the three-workout window without crashing" do
    user = user_fixture() |> provision_timezone("Etc/UTC")

    complete(user, ~U[2025-08-25 09:00:00Z], 1_200,
      source_kind: :plan,
      definition: structured_definition("Baseline", 100)
    )

    complete(user, ~U[2025-08-26 09:00:00Z], 1_200,
      source_kind: :plan,
      definition: structured_definition("Exploration", 200)
    )

    for day <- 27..29 do
      complete(
        user,
        DateTime.new!(~D[2025-08-01], ~T[09:00:00Z]) |> DateTime.add(day - 1, :day),
        300
      )
    end

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2025-09-01 12:00:00Z])
    assert slot.exploration_allowed?
  end

  test "uses completed_at for timezone boundaries and ignores inserted_at metadata" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")
    session = complete(user, ~U[2025-09-01 06:59:59Z], 1_200)
    assert DateTime.compare(session.inserted_at, session.completed_at) == :gt

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2025-09-01 08:00:00Z])
    assert slot.completed_sec == 0
    assert slot.home_state == :workout_needed
  end

  test "surfaces only typed transient, limiter, and preference feedback" do
    user = user_fixture() |> provision_timezone("Etc/UTC")

    complete(user, ~U[2025-09-01 12:00:00Z], 1_200,
      low_energy: true,
      limiter: :legs,
      preference: :avoid
    )

    assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2025-09-02 12:00:00Z])
    assert slot.feedback.transient == [:low_energy]
    assert slot.feedback.limiters == [:legs]
    assert slot.feedback.preferences == [:avoid]
  end

  defp complete(user, completed_at, duration, opts \\ []) do
    source_kind = opts[:source_kind] || :manual

    %BurpeeTrainer.Workouts.WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: source_kind,
      display_name_snapshot: if(source_kind == :plan, do: "Historical plan"),
      program_snapshot: compiled_snapshot(opts[:definition]),
      content_hash: if(opts[:definition], do: String.duplicate("a", 64)),
      burpee_type: opts[:type] || :six_count,
      burpee_count_actual: opts[:actual_reps] || 20,
      duration_sec_actual: duration,
      duration_sec_planned: opts[:planned],
      completed_at: completed_at,
      capture_mode: :logged,
      context_low_energy: opts[:low_energy] || false,
      primary_limiter: opts[:limiter],
      preference_feedback: opts[:preference]
    }
    |> Repo.insert!()
  end

  defp structured_definition(name, recovery_sec) do
    work_sec = div(1_200 - recovery_sec, 10)

    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_duration_sec" => 1_200,
      "target_reps" => 10,
      "pacing_style" => "even",
      "rationale" => "Historical structure",
      "events" => [
        %{
          "kind" => "work",
          "reps" => 5,
          "sec_per_burpee" => 5.0,
          "sec_per_rep" => work_sec * 1.0
        },
        %{"kind" => "rest", "duration_sec" => recovery_sec * 1.0},
        %{
          "kind" => "work",
          "reps" => 5,
          "sec_per_burpee" => work_sec * 1.0,
          "sec_per_rep" => work_sec * 1.0
        }
      ]
    }
  end

  defp compiled_snapshot(nil), do: nil

  defp compiled_snapshot(definition) do
    {:ok, parsed} = BurpeeTrainer.PlanCompiler.WorkoutDefinition.new(definition)
    {:ok, program} = PlanCompiler.compile(parsed)
    BurpeeTrainer.PlanCompiler.ProgramHash.canonical_map(program)
  end

  describe "sign-up week" do
    # 2026-10-05 is a Monday; 2026-10-09 Friday, 10 Saturday, 11 Sunday.
    test "is pro-rated to 20 minutes per remaining day with standard slots only" do
      for {signed_up, target} <- [
            {~U[2026-10-09 09:00:00Z], 3_600},
            {~U[2026-10-10 09:00:00Z], 2_400},
            {~U[2026-10-11 09:00:00Z], 1_200}
          ] do
        user = user_fixture() |> provision_timezone("Etc/UTC") |> sign_up_at(signed_up)

        assert {:ok, slot} =
                 Policy.required_slot(Scope.for_user(user), DateTime.add(signed_up, 3_600))

        assert slot.weekly_target_sec == target
        assert slot.remaining_sec == target
        assert slot.strategy == :standard
        assert slot.duration_sec == 1_200
      end
    end

    test "a Saturday sign-up trains 20 minutes on Sunday too, never a catch-up" do
      user =
        user_fixture() |> provision_timezone("Etc/UTC") |> sign_up_at(~U[2026-10-10 09:00:00Z])

      complete(user, ~U[2026-10-10 10:00:00Z], 1_200)

      assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2026-10-11 09:00:00Z])
      assert slot.remaining_sec == 1_200
      assert slot.strategy == :standard
      assert slot.duration_sec == 1_200
    end

    test "is resolved in the user's timezone across a DST change" do
      # 2026-03-07 10:00 PST is a Saturday; the clocks change on Sunday 2026-03-08.
      user =
        user_fixture()
        |> provision_timezone("America/Los_Angeles")
        |> sign_up_at(~U[2026-03-07 18:00:00Z])

      assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2026-03-07 20:00:00Z])
      assert slot.weekly_target_sec == 2_400
      assert slot.strategy == :standard
    end

    test "every later week has the full target and weekend catch-up" do
      user =
        user_fixture() |> provision_timezone("Etc/UTC") |> sign_up_at(~U[2026-09-01 09:00:00Z])

      assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), ~U[2026-10-10 09:00:00Z])
      assert slot.weekly_target_sec == 4_800
      assert slot.strategy == :catch_up
      assert slot.duration_sec == 4_800
    end

    property "slots never exceed the remainder, and the sign-up week has no catch-up" do
      check all(
              sign_up_day <- integer(0..400),
              days_after <- integer(0..20),
              hour <- integer(0..23),
              max_runs: 60
            ) do
        signed_up = DateTime.add(~U[2025-01-01 08:00:00Z], sign_up_day, :day)
        now = DateTime.add(signed_up, days_after * 86_400 + hour * 3_600, :second)
        user = user_fixture() |> provision_timezone("Etc/UTC") |> sign_up_at(signed_up)

        assert {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)
        assert slot.duration_sec <= slot.remaining_sec

        sign_up_week? =
          Date.beginning_of_week(DateTime.to_date(signed_up)) ==
            Date.beginning_of_week(DateTime.to_date(now))

        if sign_up_week? or Date.day_of_week(DateTime.to_date(now)) <= 5 do
          assert slot.strategy == :standard
          assert slot.duration_sec <= 1_200
        end
      end
    end
  end

  defp provision_timezone(user, timezone) do
    Repo.update_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^user.id),
      set: [timezone: timezone, timezone_provisioned: true]
    )

    Repo.get!(BurpeeTrainer.Accounts.User, user.id)
  end
end
