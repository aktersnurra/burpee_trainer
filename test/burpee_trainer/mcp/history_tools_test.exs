defmodule BurpeeTrainer.Mcp.HistoryToolsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{History, Mcp, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy

  defp call(scope, name, arguments \\ %{}) do
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

  # Today's session is a second ago, so it is never in the future; earlier ones at noon.
  defp days_ago(0), do: DateTime.add(DateTime.utc_now(:second), -1)

  defp days_ago(days),
    do: Date.utc_today() |> Date.add(-days) |> DateTime.new!(~T[12:00:00], "Etc/UTC")

  defp logged(user, days, attrs) do
    free_form_session_fixture(user, Map.put(attrs, :completed_at, days_ago(days)))
  end

  setup do
    user = user_fixture()
    {:ok, user: user, scope: Scope.for_user(user)}
  end

  describe "get_week" do
    test "the week's minutes, what is done and left, the streak and the level",
         %{user: user, scope: scope} do
      logged(user, 0, %{
        burpee_type: "six_count",
        burpee_count_actual: 120,
        duration_sec_actual: 1200
      })

      {:ok, week} = call(scope, "get_week")
      {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))

      assert week["minutes_done"] == div(slot.completed_sec, 60)
      assert week["minutes_target"] == div(slot.weekly_target_sec, 60)
      assert week["minutes_left"] == div(slot.remaining_sec, 60)
      assert week["today"] in ~w[workout_needed done_today week_complete]

      assert [%{"status" => "done", "burpee_type" => "six_count", "minutes" => 20} | _] =
               week["window"]

      assert is_integer(week["streak_weeks"])
      assert is_binary(week["level"])
    end
  end

  describe "get_progress" do
    test "one gauge per burpee type, as Progress shows them", %{user: user, scope: scope} do
      goal_fixture(user, %{
        burpee_type: "six_count",
        burpee_count_target: 150,
        duration_sec_target: 1200
      })

      logged(user, 1, %{
        burpee_type: "six_count",
        burpee_count_actual: 120,
        duration_sec_actual: 1200
      })

      {:ok, %{"gauges" => [six, seal], "level" => level}} = call(scope, "get_progress")

      assert six["burpee_type"] == "six_count"
      assert six["kind"] == "goal"
      assert six["goal"]["reps"] == 150
      assert six["best"] == 120
      assert seal == %{"burpee_type" => "navy_seal", "kind" => "none"}
      assert is_binary(level)
    end
  end

  describe "query_history" do
    test "filters compose: type, dates, reps, tags, capture mode", %{user: user, scope: scope} do
      a =
        logged(user, 1, %{
          burpee_type: "six_count",
          burpee_count_actual: 120,
          duration_sec_actual: 1200
        })

      b =
        logged(user, 3, %{
          burpee_type: "navy_seal",
          burpee_count_actual: 40,
          duration_sec_actual: 1200
        })

      c =
        logged(user, 10, %{
          burpee_type: "six_count",
          burpee_count_actual: 90,
          duration_sec_actual: 1200,
          tags: "sore,heat"
        })

      ids = fn args ->
        {:ok, %{"sessions" => sessions}} = call(scope, "query_history", args)
        Enum.map(sessions, & &1["id"])
      end

      assert ids.(%{}) == [a.id, b.id, c.id]
      assert ids.(%{"burpee_type" => "six_count"}) == [a.id, c.id]
      assert ids.(%{"from" => Date.to_iso8601(Date.add(Date.utc_today(), -5))}) == [a.id, b.id]
      assert ids.(%{"to" => Date.to_iso8601(Date.add(Date.utc_today(), -2))}) == [b.id, c.id]
      assert ids.(%{"min_reps" => 50, "max_reps" => 100}) == [c.id]
      assert ids.(%{"tags" => ["heat"]}) == [c.id]
      assert ids.(%{"burpee_type" => "six_count", "min_reps" => 100}) == [a.id]
      assert ids.(%{"capture_mode" => "tracked"}) == []
    end

    test "a session carries what the app recorded about it", %{user: user, scope: scope} do
      logged(user, 1, %{
        burpee_type: "six_count",
        burpee_count_actual: 120,
        duration_sec_actual: 1200
      })

      {:ok, %{"sessions" => [session]}} = call(scope, "query_history")

      assert session["burpee_type"] == "six_count"
      assert session["reps"] == 120
      assert session["duration_sec"] == 1200
      assert session["pace_sec"] == 10.0
      assert session["reps_per_20_min"] == 120
      assert session["capture_mode"] == "logged"
      assert session["date"] == Date.to_iso8601(Date.add(Date.utc_today(), -1))
      assert Map.has_key?(session, "note_post")
      assert Map.has_key?(session, "tags")
    end

    test "paging returns every session exactly once", %{user: user, scope: scope} do
      made = for day <- 1..7, do: logged(user, day, %{}).id

      pages =
        Stream.unfold(:start, fn
          nil ->
            nil

          cursor ->
            args =
              %{"limit" => 3}
              |> then(&if cursor == :start, do: &1, else: Map.put(&1, "cursor", cursor))

            {:ok, page} = call(scope, "query_history", args)
            {Enum.map(page["sessions"], & &1["id"]), page["next_cursor"]}
        end)
        |> Enum.to_list()

      assert List.flatten(pages) == made
      assert Enum.map(pages, &length/1) == [3, 3, 1]
    end

    test "another user's sessions never appear", %{user: user, scope: scope} do
      logged(user_fixture(), 1, %{})
      mine = logged(user, 2, %{})
      {:ok, %{"sessions" => sessions}} = call(scope, "query_history")
      assert Enum.map(sessions, & &1["id"]) == [mine.id]
    end

    test "bad filters are refused with the reason", %{scope: scope} do
      for args <- [
            %{"burpee_type" => "jumping_jack"},
            %{"from" => "yesterday"},
            %{"limit" => 0},
            %{"cursor" => "garbage"},
            %{"unknown" => 1}
          ] do
        assert {:error, _} = call(scope, "query_history", args)
      end
    end
  end

  describe "history_stats" do
    test "weekly minutes equal Progress's, split by type", %{user: user, scope: scope} do
      for {days, type, reps} <- [
            {0, "six_count", 120},
            {1, "navy_seal", 40},
            {8, "six_count", 110}
          ] do
        logged(user, days, %{
          burpee_type: type,
          burpee_count_actual: reps,
          duration_sec_actual: 1200
        })
      end

      {:ok, %{"periods" => periods}} = call(scope, "history_stats", %{"group_by" => "week"})

      {:ok, weeks} =
        History.weeks(Workouts.list_sessions(scope), user, DateTime.utc_now(), "twelve_weeks")

      for week <- weeks, week.minutes > 0 do
        period = Enum.find(periods, &(&1["start"] == Date.to_iso8601(week.start)))
        assert period, "no stats for #{week.start}"
        assert period["minutes"] == week.minutes
        assert period["target_met"] == week.target?
      end

      by_type = Enum.flat_map(periods, & &1["by_type"])

      assert Enum.find(
               by_type,
               &(&1["burpee_type"] == "six_count" and &1["best_reps_per_20_min"] == 120)
             )
    end

    test "monthly groups use calendar months", %{user: user, scope: scope} do
      logged(user, 0, %{burpee_count_actual: 100, duration_sec_actual: 1200})
      {:ok, %{"periods" => [period]}} = call(scope, "history_stats", %{"group_by" => "month"})
      today = Date.utc_today()
      assert period["start"] == Date.to_iso8601(Date.beginning_of_month(today))
      assert period["sessions"] == 1
      refute Map.has_key?(period, "target_met")
    end
  end
end
