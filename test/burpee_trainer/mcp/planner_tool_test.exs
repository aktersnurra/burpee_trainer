defmodule BurpeeTrainer.Mcp.PlannerToolTest do
  use BurpeeTrainer.DataCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Mcp, Repo, Workouts}
  alias BurpeeTrainer.Coach.{PlanNextWorkoutJob, Policy}
  alias BurpeeTrainer.Workouts.CoachRecommendation

  defp call(scope, arguments) do
    {:reply, %{"result" => result}} =
      Mcp.handle(scope, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "plan_next_workout", "arguments" => arguments}
      })

    if result["isError"],
      do: {:error, hd(result["content"])["text"]},
      else: {:ok, result["structuredContent"]}
  end

  defp recommendation(scope, slot),
    do:
      Repo.get_by!(CoachRecommendation,
        user_id: scope.user.id,
        slot_key: slot.slot_key,
        slot_date: slot.slot_date
      )

  setup do
    scope = scope_fixture(%{"timezone" => "Etc/UTC"})
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, scope: scope, slot: slot}
  end

  test "Claude's pick lands on Home with its reason, marked as Claude's",
       %{scope: scope, slot: slot} do
    plan =
      plan_fixture(scope.user, %{
        burpee_type: to_string(slot.burpee_type),
        target_reps: 30,
        target_duration_sec: slot.duration_sec
      })

    {:ok, planned} =
      call(scope, %{"workout_id" => plan.id, "rationale" => "An easy one after two hard days."})

    assert planned["workout"]["id"] == plan.id
    assert planned["date"] == Date.to_iso8601(slot.slot_date)

    selection = Workouts.current_home_selection(scope, slot)
    assert selection.plan.id == plan.id
    assert selection.rationale == "An easy one after two hard days."
    assert recommendation(scope, slot).planned_by == :mcp
  end

  test "Claude can design the workout it plans", %{scope: scope, slot: slot} do
    reps = 60

    workout = %{
      "name" => "Steady sixties",
      "rationale" => "Even reps to build the base.",
      "burpee_type" => to_string(slot.burpee_type),
      "target_reps" => reps,
      "target_duration_sec" => slot.duration_sec,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "phases" => [
        %{
          "sets" =>
            List.duplicate(
              %{"reps" => div(reps, 2), "sec_per_rep" => 15.0, "sec_per_burpee" => 5.0},
              2
            ),
          "rests" => [%{"share" => 1}]
        }
      ]
    }

    {:ok, planned} =
      call(scope, %{"workout" => workout, "rationale" => "Even reps to build the base."})

    assert Workouts.current_home_selection(scope, slot).plan.name == "Steady sixties"
    assert planned["workout"]["name"] == "Steady sixties"
  end

  test "a workout that does not fit the next session is refused", %{scope: scope, slot: slot} do
    other_type = if slot.burpee_type == :six_count, do: "navy_seal", else: "six_count"

    wrong_type =
      plan_fixture(scope.user, %{burpee_type: other_type, target_duration_sec: slot.duration_sec})

    wrong_length =
      plan_fixture(scope.user, %{
        burpee_type: to_string(slot.burpee_type),
        target_duration_sec: 300
      })

    for plan <- [wrong_type, wrong_length] do
      assert {:error, reason} = call(scope, %{"workout_id" => plan.id, "rationale" => "Because."})
      assert reason =~ "next session"
    end

    assert {:error, _} = call(scope, %{"rationale" => "Nothing to plan."})
  end

  test "the in-app planner never replaces a slot Claude or the owner planned",
       %{scope: scope, slot: slot} do
    plan =
      plan_fixture(scope.user, %{
        burpee_type: to_string(slot.burpee_type),
        target_duration_sec: slot.duration_sec
      })

    {:ok, _} = call(scope, %{"workout_id" => plan.id, "rationale" => "Planned the night before."})

    args = %{"user_id" => scope.user.id, "slot_key" => slot.slot_key}
    assert {:cancel, :already_planned} = perform_job(PlanNextWorkoutJob, args)

    recommendation(scope, slot) |> Ecto.Changeset.change(planned_by: :owner) |> Repo.update!()
    assert {:cancel, :already_planned} = perform_job(PlanNextWorkoutJob, args)

    # The planner's own pick, or none, is still the planner's to replace.
    recommendation(scope, slot) |> Ecto.Changeset.change(planned_by: :coach) |> Repo.update!()
    assert {:cancel, :provider_unavailable} = perform_job(PlanNextWorkoutJob, args)
  end

  test "the owner choosing on Home marks the slot as theirs", %{scope: scope, slot: slot} do
    plan =
      plan_fixture(scope.user, %{
        burpee_type: to_string(slot.burpee_type),
        target_duration_sec: slot.duration_sec
      })

    {:ok, expected} = Workouts.ensure_home_selection(scope, slot)
    assert recommendation(scope, slot).planned_by == nil

    {:ok, _} = Workouts.select_home_workout(scope, expected, plan.id)
    assert recommendation(scope, slot).planned_by == :owner
  end
end
