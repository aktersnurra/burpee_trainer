defmodule BurpeeTrainer.Mcp.SessionToolsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Mcp, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{MemoryJob, PlanNextWorkoutJob, SummaryJob}
  alias BurpeeTrainer.Workouts.WorkoutSession

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

  defp queued(user, worker),
    do:
      Repo.exists?(
        from j in Oban.Job, where: j.worker == ^inspect(worker) and j.args["user_id"] == ^user.id
      )

  setup do
    Repo.delete_all(Oban.Job)
    user = user_fixture()
    {:ok, user: user, scope: Scope.for_user(user)}
  end

  describe "log_session" do
    test "a workout done away from the phone is kept as logged by hand",
         %{user: user, scope: scope} do
      yesterday = Date.add(Date.utc_today(), -1)

      {:ok, %{"session" => session}} =
        call(scope, "log_session", %{
          "burpee_type" => "navy_seal",
          "reps" => 45,
          "duration_sec" => 1200,
          "date" => Date.to_iso8601(yesterday),
          "note_post" => "Outside, felt strong.",
          "tags" => ["outdoors"]
        })

      assert session["capture_mode"] == "logged"
      assert session["date"] == Date.to_iso8601(yesterday)
      assert session["reps"] == 45
      assert session["tags"] == ["outdoors"]

      stored = Repo.get!(WorkoutSession, session["id"])
      assert stored.source_kind == :manual
      assert stored.state == :completed

      assert queued(user, SummaryJob)
      refute queued(user, MemoryJob)
    end

    test "logged sessions count toward the week like any other", %{scope: scope} do
      {:ok, %{"minutes_done" => before}} = call(scope, "get_week", %{})

      {:ok, _} =
        call(scope, "log_session", %{
          "burpee_type" => "six_count",
          "reps" => 100,
          "duration_sec" => 1200
        })

      {:ok, %{"minutes_done" => after_log}} = call(scope, "get_week", %{})
      assert after_log == before + 20
    end

    test "a session the app would not keep is refused", %{scope: scope} do
      tomorrow = Date.to_iso8601(Date.add(Date.utc_today(), 1))

      for args <- [
            %{"burpee_type" => "six_count", "reps" => 0, "duration_sec" => 1200},
            %{"burpee_type" => "six_count", "reps" => 10, "duration_sec" => 0},
            %{"burpee_type" => "plank", "reps" => 10, "duration_sec" => 60},
            %{
              "burpee_type" => "six_count",
              "reps" => 10,
              "duration_sec" => 60,
              "date" => tomorrow
            },
            %{"burpee_type" => "six_count", "reps" => 10, "duration_sec" => 60, "mood" => 5},
            %{
              "burpee_type" => "six_count",
              "reps" => 10,
              "duration_sec" => 60,
              "low_energy" => true,
              "high_energy" => true
            }
          ] do
        assert {:error, _} = call(scope, "log_session", args), "kept #{inspect(args)}"
      end

      assert Workouts.list_sessions(scope) == []
    end
  end

  describe "edit_session" do
    test "the athlete's feedback can be corrected; the result cannot", %{user: user, scope: scope} do
      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan, %{"note_post" => "Tired."})
      {:ok, _} = Workouts.archive_plan(scope, plan.id)
      # Completing it in the app queued its own jobs; only the correction's count here.
      Repo.delete_all(Oban.Job)

      {:ok, %{"session" => edited}} =
        call(scope, "edit_session", %{
          "id" => session.id,
          "note_post" => "Tired, slept badly.",
          "mood" => -1,
          "primary_limiter" => "legs",
          "tags" => ["sleep"]
        })

      assert edited["note_post"] == "Tired, slept badly."
      assert edited["mood"] == -1
      assert edited["primary_limiter"] == "legs"
      assert edited["tags"] == ["sleep"]
      assert edited["reps"] == session.burpee_count_actual
      assert queued(user, SummaryJob)
      refute queued(user, MemoryJob)

      assert {:error, _} = call(scope, "edit_session", %{"id" => session.id, "reps" => 999})
    end

    test "the database still refuses a change to a session's result", %{user: user} do
      session = session_from_plan_fixture(user, plan_fixture(user))

      assert_raise Exqlite.Error, ~r/exact_once_completion/, fn ->
        Repo.update_all(from(s in WorkoutSession, where: s.id == ^session.id),
          set: [burpee_count_actual: 999]
        )
      end
    end

    test "another user's session cannot be corrected or deleted", %{scope: scope} do
      theirs = free_form_session_fixture(user_fixture())

      assert {:error, _} =
               call(scope, "edit_session", %{"id" => theirs.id, "note_post" => "mine"})

      assert {:error, _} = call(scope, "delete_session", %{"id" => theirs.id})
      assert Repo.get(WorkoutSession, theirs.id)
    end
  end

  describe "delete_session" do
    test "a session is deleted and the coach's note follows", %{user: user, scope: scope} do
      session = free_form_session_fixture(user)
      {:ok, %{"deleted" => id}} = call(scope, "delete_session", %{"id" => session.id})
      assert id == session.id
      refute Repo.get(WorkoutSession, session.id)
      assert queued(user, SummaryJob)
      refute queued(user, PlanNextWorkoutJob)
    end
  end
end
