defmodule BurpeeTrainer.Mcp.HistoryToolsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{History, Mcp, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.WorkoutSession
  import Ecto.Query

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

  test "range summaries and page coverage describe only selected owner work", %{
    user: user,
    scope: scope
  } do
    logged(user_fixture(), 1, %{})
    logged(user, 1, %{burpee_count_actual: 10, duration_sec_actual: 61})
    logged(user, 2, %{burpee_type: "navy_seal", burpee_count_actual: 20, duration_sec_actual: 62})
    {:ok, result} = call(scope, "history_stats")
    assert result["group_by"] == "range"
    assert result["periods"] == []
    assert result["summary"]["actual_reps"] == 30
    assert result["summary"]["elapsed_seconds"] == 123
    assert result["summary"]["average_pace_sec"] == nil
    assert result["context"]["matched_sessions"] == 2
    assert result["context"]["complete_range"]
    assert result["context"]["applied_filters"]["warmup"] == "include"
    {:ok, first} = call(scope, "query_history", %{"limit" => 1})
    refute first["context"]["complete_range"]
    assert first["context"]["matched_sessions"] == nil
    {:ok, last} = call(scope, "query_history", %{"limit" => 1, "cursor" => first["next_cursor"]})
    assert last["next_cursor"] == nil
    assert last["context"]["continuation_exhausted"]
    refute last["context"]["complete_range"]
    assert last["context"]["returned_sessions"] == 1
  end

  test "daily grouping marks requested and unfinished periods", %{user: user, scope: scope} do
    session = logged(user, 0, %{burpee_count_actual: 10, duration_sec_actual: 61})
    date = DateTime.to_date(session.completed_at)
    selected_date = Date.to_iso8601(date)
    day_end = date |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    {:ok, result} =
      call(scope, "history_stats", %{
        "group_by" => "day",
        "from" => selected_date,
        "to" => selected_date
      })

    {:ok, cutoff, 0} = DateTime.from_iso8601(result["context"]["effective_utc_cutoff"])
    {:ok, as_of, 0} = DateTime.from_iso8601(result["context"]["as_of"])
    partial? = DateTime.compare(cutoff, day_end) == :lt
    expected_cutoff = if DateTime.compare(as_of, day_end) == :lt, do: as_of, else: day_end

    assert DateTime.compare(cutoff, expected_cutoff) == :eq
    assert [%{"start" => ^selected_date, "partial" => ^partial?}] = result["periods"]

    assert result["context"]["requested_local_boundaries"] == %{
             "from" => selected_date,
             "to" => selected_date
           }
  end

  test "aggregate refuses a real overflowing page rather than returning partial totals", %{
    user: user,
    scope: scope
  } do
    logged(user, 1, %{})
    logged(user, 2, %{})
    assert {:error, message} = BurpeeTrainer.Mcp.HistoryCoverage.fetch(scope, %{}, 1)
    assert message =~ "narrow"
    assert {:ok, rows} = BurpeeTrainer.Mcp.HistoryCoverage.fetch(scope, %{}, 2)
    assert [_, _] = rows
  end

  test "analytics resource is discoverable and static across owners", %{scope: scope} do
    request = fn owner, method, params ->
      {:reply, %{"result" => result}} =
        Mcp.handle(owner, %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

      result
    end

    uri = "burpee://analytics-guide"
    listed = request.(scope, "resources/list", %{})

    assert Enum.any?(
             listed["resources"],
             &(&1["uri"] == uri and &1["mimeType"] == "text/markdown")
           )

    result = request.(scope, "resources/read", %{"uri" => uri})

    assert %{"contents" => [%{"uri" => ^uri, "mimeType" => "text/markdown", "text" => text}]} =
             result

    assert byte_size(text) > 0
    assert result == request.(Scope.for_user(user_fixture()), "resources/read", %{"uri" => uri})
  end

  test "filtered weeks keep whole-week targets and exact actual metrics", %{
    user: user,
    scope: scope
  } do
    free_form_session_fixture(user, %{
      completed_at: ~U[2026-03-24 12:00:00Z],
      burpee_type: "navy_seal",
      duration_sec_actual: 4800
    })

    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged,
      burpee_type: :six_count,
      duration_sec_actual: 61,
      duration_sec_planned: 1200,
      burpee_count_actual: 0,
      completed_at: ~U[2026-03-25 12:00:00Z]
    })

    free_form_session_fixture(user, %{
      completed_at: ~U[2026-03-25 13:00:00Z],
      tags: "warmup",
      burpee_count_actual: 10,
      duration_sec_actual: 62
    })

    args = %{
      "from" => "2026-03-25",
      "to" => "2026-03-25",
      "burpee_type" => "six_count",
      "group_by" => "week"
    }

    {:ok, result} = call(scope, "history_stats", args)

    assert [
             %{
               "target_met" => true,
               "target_seconds" => 4800,
               "partial" => true,
               "target_scope" => "whole_week_all_types_unfiltered_owner_history"
             }
           ] = result["periods"]

    assert %{
             "actual_reps" => 10,
             "elapsed_seconds" => 123,
             "credited_seconds" => 61,
             "missing_actual_reps" => 0,
             "reps" => 0,
             "measurement_samples" => 1
           } = result["summary"]

    {:ok, only} = call(scope, "history_stats", Map.put(args, "warmup", "only"))
    assert only["summary"]["elapsed_seconds"] == 62
    assert only["summary"]["credited_seconds"] == 0
    {:ok, excluded} = call(scope, "history_stats", Map.put(args, "warmup", "exclude"))
    assert excluded["summary"]["elapsed_seconds"] == 61
    {:ok, empty} = call(scope, "history_stats", Map.put(args, "min_duration_sec", 63))
    assert empty["periods"] == []
    assert empty["summary"]["sessions"] == 0
    assert empty["context"]["complete_range"]
  end

  test "DST local day metadata and grouping share exact boundaries", %{user: user} do
    scope = Scope.for_user(%{user | timezone: "Europe/Stockholm"})

    for at <- [
          ~U[2026-03-28 22:59:59Z],
          ~U[2026-03-28 23:00:00Z],
          ~U[2026-03-29 21:59:59Z],
          ~U[2026-03-29 22:00:00Z]
        ] do
      free_form_session_fixture(user, %{completed_at: at})
    end

    {:ok, result} =
      call(scope, "history_stats", %{
        "from" => "2026-03-29",
        "to" => "2026-03-29",
        "group_by" => "day"
      })

    assert [%{"start" => "2026-03-29", "partial" => false, "sessions" => 2}] = result["periods"]
    assert result["context"]["from_utc_inclusive"] == "2026-03-28T23:00:00Z"
    assert result["context"]["effective_utc_cutoff"] == "2026-03-29T22:00:00Z"
    refute result["context"]["cutoff_inclusive"]
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

    test "a camera session carries its fatigue; others carry none", %{user: user, scope: scope} do
      camera = logged(user, 1, %{burpee_count_actual: 140, duration_sec_actual: 1200})
      logged(user, 2, %{burpee_count_actual: 140, duration_sec_actual: 1200})

      Repo.update_all(from(s in WorkoutSession, where: s.id == ^camera.id),
        set: [fatigue_coverage: 0.97, kept_up: false, slip_at_sec: 720.0, fatigue_decline: 0.08]
      )

      {:ok, %{"sessions" => [tracked, plain]}} = call(scope, "query_history")

      assert %{"kept_up" => false, "slip_at_sec" => 720.0, "decline" => 0.08} =
               tracked["fatigue"]

      assert plain["fatigue"] == nil
      # The planner reads the same shape.
      assert [%{"fatigue" => %{"slip_at_sec" => 720.0}}, %{"fatigue" => nil}] =
               BurpeeTrainer.Coach.AgentPrompt.context(scope)
               |> Jason.encode!()
               |> Jason.decode!()
               |> Map.fetch!("recent_sessions")
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
