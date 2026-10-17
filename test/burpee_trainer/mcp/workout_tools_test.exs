defmodule BurpeeTrainer.Mcp.WorkoutToolsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Mcp, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  defp call(scope, name, arguments) do
    {:reply, %{"result" => result}} =
      Mcp.handle(scope, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    if result["isError"],
      do: {:error, hd(result["content"])["text"]},
      else: {:ok, result["structuredContent"]}
  end

  # Ten sets of 15 even-paced six-counts in 20 minutes: 150 reps at 6 s a rep is 15 min of
  # work, leaving five minutes for the nine rests between sets.
  defp ten_by_fifteen(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Tens of fifteen",
        "rationale" => "Short sets keep the pace honest.",
        "burpee_type" => "six_count",
        "target_reps" => 150,
        "target_duration_sec" => 1200,
        "pacing_style" => "even",
        "recovery" => "required",
        "timed_rests" => [],
        "phases" => [
          %{
            "sets" =>
              List.duplicate(%{"reps" => 15, "sec_per_rep" => 6.0, "sec_per_burpee" => 4.5}, 10),
            "rests" => List.duplicate(%{"share" => 1}, 9)
          }
        ]
      },
      overrides
    )
  end

  setup do
    user = user_fixture()
    {:ok, user: user, scope: Scope.for_user(user)}
  end

  test "a workout is created through the app's fitter and compiler, then read back",
       %{scope: scope} do
    {:ok, %{"workout" => created}} = call(scope, "create_workout", ten_by_fifteen())

    {:ok, %{"workout" => workout}} = call(scope, "get_workout", %{"id" => created["id"]})

    assert workout["name"] == "Tens of fifteen"
    assert workout["target_reps"] == 150
    assert workout["pacing_style"] == "even"
    assert workout["summary"] =~ "10 sets of 15"
    works = Enum.filter(workout["definition"]["events"], &(&1["kind"] == "work"))
    rests = Enum.filter(workout["definition"]["events"], &(&1["kind"] == "rest"))
    assert length(works) == 10
    assert length(rests) == 9
    assert Enum.uniq(Enum.map(rests, & &1["duration_sec"])) |> length() == 1

    {:ok, %{"workouts" => listed}} = call(scope, "list_workouts", %{})
    assert Enum.any?(listed, &(&1["id"] == created["id"] and &1["pacing_style"] == "even"))
  end

  test "editing a workout unchanged stores an equal workout and archives the old one",
       %{scope: scope} do
    {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", ten_by_fifteen())
    {:ok, %{"workout" => before}} = call(scope, "get_workout", %{"id" => id})

    {:ok, %{"workout" => edited}} =
      call(scope, "edit_workout", Map.put(before["editable"], "id", id))

    {:ok, %{"workout" => after_edit}} = call(scope, "get_workout", %{"id" => edited["id"]})

    assert edited["id"] != id
    assert after_edit["definition"] == before["definition"]
    assert Repo.get!(WorkoutPlan, id).state == :archived
  end

  # The sets as Claude writes them: `{reps, sec_per_rep, sec_per_burpee}`.
  defp exact_workout(sets, rests, overrides) do
    Map.merge(
      %{
        "name" => "Exact rests",
        "rationale" => "Rests as the athlete asked.",
        "burpee_type" => "six_count",
        "target_reps" => sets |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "phases" => [
          %{
            "sets" =>
              Enum.map(sets, fn {reps, cadence, active} ->
                %{"reps" => reps, "sec_per_rep" => cadence, "sec_per_burpee" => active}
              end),
            "rests" => Enum.map(rests, &%{"sec" => &1})
          }
        ]
      },
      overrides
    )
  end

  defp rests_of(workout),
    do: for(%{"kind" => "rest", "duration_sec" => d} <- workout["definition"]["events"], do: d)

  test "editing a workout unchanged keeps unequal rests exactly", %{scope: scope} do
    # Three sets of 10 at 10 s per rep (3 s moving), rests of 20 and 60 s: 6:13 in all.
    workout =
      exact_workout(List.duplicate({10, 10.0, 3.0}, 3), [20, 60], %{
        "target_duration_sec" => 373
      })

    {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", workout)
    {:ok, %{"workout" => before}} = call(scope, "get_workout", %{"id" => id})
    assert rests_of(before) == [20.0, 60.0]
    assert hd(before["editable"]["phases"])["rests"] == [%{"sec" => 20.0}, %{"sec" => 60.0}]

    {:ok, %{"workout" => edited}} =
      call(scope, "edit_workout", Map.put(before["editable"], "id", id))

    {:ok, %{"workout" => after_edit}} = call(scope, "get_workout", %{"id" => edited["id"]})
    assert after_edit["definition"] == before["definition"]
    assert after_edit["summary"] =~ "rests 20, 60 s"
  end

  test "sets back to back read back as a rest of 0", %{scope: scope} do
    workout = exact_workout([{4, 10.0, 3.0}, {3, 10.0, 3.0}], [0], %{"target_duration_sec" => 63})

    {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", workout)
    {:ok, %{"workout" => read}} = call(scope, "get_workout", %{"id" => id})

    assert rests_of(read) == []
    assert hd(read["editable"]["phases"])["rests"] == [%{"sec" => 0}]
    assert read["summary"] =~ "sets back to back"
  end

  describe "the workouts Claude tried to build" do
    test "the Steady Sixty: one rep every 20 s ends at 19:44, and the error says so", %{
      scope: scope
    } do
      workout = exact_workout([{60, 20.0, 4.0}], [], %{"target_duration_sec" => 1200})

      assert {:error, reason} = call(scope, "create_workout", workout)
      assert reason =~ "the 16 s after the last rep is not part of the workout"
      assert reason =~ "target_duration_sec 1184"

      {:ok, %{"workout" => created}} =
        call(scope, "create_workout", Map.put(workout, "target_duration_sec", 1184))

      assert created["summary"] =~ "1 set of 60, 20 s per rep (4 s moving)"
    end

    test "75 reps at a 15 s cadence with exact 20.5 s rests", %{scope: scope} do
      # 5 × 15 at 15 s per rep (5 s moving): 5 × 3:35 of sets, 4 × 10 s tails, 4 × 20.5 s.
      workout =
        exact_workout(List.duplicate({15, 15.0, 5.0}, 5), List.duplicate(20.5, 4), %{
          "target_duration_sec" => 1197
        })

      {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", workout)
      {:ok, %{"workout" => read}} = call(scope, "get_workout", %{"id" => id})

      assert rests_of(read) == List.duplicate(20.5, 4)
      assert read["summary"] =~ "20.5 s between sets"
    end

    test "150 six-counts with alternating 45 and 50 s rests", %{scope: scope} do
      rests = [45, 50, 45, 50, 45, 50, 45, 50, 45]

      # 10 × 15 at 5 s per rep (4 s moving): 10 × 74 s of sets, 9 × 1 s tails, 425 s of rests.
      workout =
        exact_workout(List.duplicate({15, 5.0, 4.0}, 10), rests, %{"target_duration_sec" => 1174})

      {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", workout)
      {:ok, %{"workout" => read}} = call(scope, "get_workout", %{"id" => id})

      assert rests_of(read) == Enum.map(rests, &(&1 * 1.0))
      assert read["summary"] =~ "rests 45, 50, 45, 50, 45, 50, 45, 50, 45 s"
    end
  end

  test "a change to one field is all an edit needs", %{scope: scope} do
    {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", ten_by_fifteen())
    {:ok, %{"workout" => before}} = call(scope, "get_workout", %{"id" => id})

    {:ok, %{"workout" => edited}} =
      call(
        scope,
        "edit_workout",
        before["editable"] |> Map.put("id", id) |> Map.put("name", "Tens again")
      )

    assert edited["name"] == "Tens again"
  end

  test "a workout the app could not run is refused with the reason", %{scope: scope} do
    # 150 reps at 9 s a rep is 22.5 minutes of work in a 20-minute workout.
    too_slow =
      ten_by_fifteen(%{
        "phases" => [
          %{
            "sets" =>
              List.duplicate(%{"reps" => 15, "sec_per_rep" => 9.0, "sec_per_burpee" => 4.5}, 10),
            "rests" => List.duplicate(%{"share" => 1}, 9)
          }
        ]
      })

    assert {:error, reason} = call(scope, "create_workout", too_slow)
    assert reason =~ "phase 1 needs"
    assert reason =~ "Take"

    assert {:error, _} = call(scope, "create_workout", ten_by_fifteen(%{"target_reps" => 140}))

    assert {:error, _} =
             call(scope, "create_workout", ten_by_fifteen(%{"name" => "six_count tens"}))

    assert {:error, _} = call(scope, "create_workout", Map.delete(ten_by_fifteen(), "phases"))
  end

  test "an edit moves Home's pick from the old workout to the new one", %{
    user: user,
    scope: scope
  } do
    {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", ten_by_fifteen())

    recommendation =
      Repo.insert!(%CoachRecommendation{
        user_id: user.id,
        slot_key: "test-slot",
        slot_date: Date.utc_today(),
        selected_workout_plan_id: id,
        home_workout_plan_id: id
      })

    {:ok, %{"workout" => before}} = call(scope, "get_workout", %{"id" => id})

    {:ok, %{"workout" => edited}} =
      call(scope, "edit_workout", Map.put(before["editable"], "id", id))

    recommendation = Repo.reload(recommendation)
    assert recommendation.home_workout_plan_id == edited["id"]
    assert recommendation.selected_workout_plan_id == edited["id"]
  end

  test "built-in and other users' workouts cannot be edited or archived", %{scope: scope} do
    theirs = plan_fixture(user_fixture())

    built_in =
      Enum.find(Workouts.list_library(scope), &is_nil(&1.user_id))

    for plan <- Enum.reject([theirs, built_in], &is_nil/1) do
      assert {:error, _} = call(scope, "archive_workout", %{"id" => plan.id})
      assert {:error, _} = call(scope, "edit_workout", Map.put(ten_by_fifteen(), "id", plan.id))
    end

    assert {:error, _} = call(scope, "get_workout", %{"id" => theirs.id})
  end

  test "archive_workout archives an owned workout", %{scope: scope} do
    {:ok, %{"workout" => %{"id" => id}}} = call(scope, "create_workout", ten_by_fifteen())

    {:ok, %{"workout" => %{"state" => "archived"}}} =
      call(scope, "archive_workout", %{"id" => id})

    refute Enum.any?(Workouts.list_library(scope), &(&1.id == id))
  end
end
