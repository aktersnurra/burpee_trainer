defmodule BurpeeTrainer.Coach.PolicyTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{PlanCompiler, Repo}

  test "uses the exact 4,800 second target and Monday begins a clean local week" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")

    complete(user, ~U[2025-08-31 23:00:00Z], 4_800)

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-01 08:00:00Z])
    assert slot.weekly_target_sec == 4_800
    assert slot.completed_sec == 0
    assert slot.remaining_sec == 4_800
    assert slot.local_date == ~D[2025-09-01]
  end

  test "home priority is week complete, then done today, then workout needed" do
    user = user_fixture() |> provision_timezone("Etc/UTC")
    monday = ~U[2025-09-01 12:00:00Z]

    assert {:ok, %{home_state: :workout_needed}} = Policy.required_slot(user, monday)

    complete(user, monday, 1_200)
    assert {:ok, %{home_state: :done_today}} = Policy.required_slot(user, monday)

    complete(user, ~U[2025-09-02 12:00:00Z], 3_600)

    assert {:ok, %{home_state: :week_complete}} =
             Policy.required_slot(user, ~U[2025-09-03 12:00:00Z])
  end

  test "weekend catch-up covers the full remainder at 2,400 seconds and is never exploration" do
    user = user_fixture() |> provision_timezone("Etc/UTC")
    complete(user, ~U[2025-09-01 12:00:00Z], 2_400)

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-06 12:00:00Z])
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

    assert {:ok, slot} = Policy.required_slot(user, now)
    assert slot.personal_best.reps == 100
    assert slot.personal_best.completed_at == DateTime.add(now, -41 * 86_400, :second)
  end

  test "catch-up ceilings are exactly 75, 60, and 50 percent at 40, 60, and 80 minutes" do
    assert Policy.catch_up_ceiling(100, 2_400) == 150
    assert Policy.catch_up_ceiling(100, 3_600) == 180
    assert Policy.catch_up_ceiling(100, 4_800) == 200
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

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-01 12:00:00Z])
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

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-01 12:00:00Z])
    assert slot.exploration_allowed?
  end

  test "uses completed_at for timezone boundaries and ignores inserted_at metadata" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")
    session = complete(user, ~U[2025-09-01 06:59:59Z], 1_200)
    assert DateTime.compare(session.inserted_at, session.completed_at) == :gt

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-01 08:00:00Z])
    assert slot.completed_sec == 0
    assert slot.home_state == :workout_needed
  end

  test "immutable fingerprint derivation rejects zero work timing" do
    work_event = %{
      kind: :work,
      reps: 10,
      sec_per_rep_us: 1_000_000,
      sec_per_burpee_us: 1_000_000
    }

    for timing <- [:sec_per_rep_us, :sec_per_burpee_us] do
      plan = %BurpeeTrainer.Workouts.WorkoutPlan{
        burpee_type: :six_count,
        target_duration_sec: 1_200,
        target_reps: 10,
        program_json: %{
          burpee_type: :six_count,
          events: [Map.put(work_event, timing, 0)],
          semantics: %{pacing_style: :even}
        }
      }

      assert {:error, error} = Policy.verify_candidate(user_fixture(), ~D[2025-09-01], plan)
      assert error.code == :invalid_recommendation_selection
    end
  end

  test "immutable fingerprint derivation rejects zero rest duration" do
    plan = %BurpeeTrainer.Workouts.WorkoutPlan{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      target_reps: 10,
      program_json: %{
        burpee_type: :six_count,
        events: [
          %{
            kind: :work,
            reps: 10,
            sec_per_rep_us: 1_000_000,
            sec_per_burpee_us: 1_000_000
          },
          %{kind: :rest, duration_ms: 0}
        ],
        semantics: %{pacing_style: :even}
      }
    }

    assert {:error, error} = Policy.verify_candidate(user_fixture(), ~D[2025-09-01], plan)
    assert error.code == :invalid_recommendation_selection
  end

  test "candidate verification rejects malformed typed program facts even without history" do
    user = user_fixture() |> provision_timezone("Etc/UTC")

    candidate = %BurpeeTrainer.Workouts.WorkoutPlan{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      target_reps: 10,
      program_json: %{
        "burpee_type" => "six_count",
        "events" => [%{"kind" => "work", "reps" => "ten"}],
        "semantics" => %{"pacing_style" => "even"}
      }
    }

    assert {:error, error} = Policy.verify_candidate(user, ~D[2025-09-01], candidate)
    assert error.code == :invalid_recommendation_selection
  end

  test "slot-day cutoff follows local midnight across DST and excludes the next local day" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")

    complete(user, ~U[2025-03-10 06:30:00Z], 1_200)
    complete(user, ~U[2025-03-10 07:30:00Z], 1_200)

    assert {:ok, slot} = Policy.required_slot_for_date(user, ~D[2025-03-09])
    assert slot.local_date == ~D[2025-03-09]
    assert slot.completed_sec == 1_200
  end

  test "surfaces only typed transient, limiter, and preference feedback" do
    user = user_fixture() |> provision_timezone("Etc/UTC")

    complete(user, ~U[2025-09-01 12:00:00Z], 1_200,
      low_energy: true,
      limiter: :legs,
      preference: :avoid
    )

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-02 12:00:00Z])
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

  defp provision_timezone(user, timezone) do
    Repo.update_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^user.id),
      set: [timezone: timezone, timezone_provisioned: true]
    )

    Repo.get!(BurpeeTrainer.Accounts.User, user.id)
  end
end
