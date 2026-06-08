defmodule BurpeeTrainerWeb.WorkoutsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/workouts" do
    test "empty state renders when no plans or videos", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts")
      assert html =~ "No workouts yet"
    end

    test "does not expose diagnostics in the normal workouts header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts")
      refute html =~ "Tracking Test"
      refute html =~ "Diagnostics"
      refute html =~ ~s(href="/tracking-test")
    end

    test "lists plans and videos together", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, _view, html} = live(conn, ~p"/workouts")

      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "renders workout page with featured instrument and rounded list", %{
      conn: conn,
      user: user
    } do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")

      assert has_element?(view, "#workouts-featured-card")
      assert has_element?(view, "#workouts-options-section")
      assert has_element?(view, "#workouts-filter-panel")
      assert has_element?(view, "#workouts-custom-session[href='/workouts/new']")
      assert has_element?(view, "#workouts-list")
      assert has_element?(view, "[data-workout-row]")
    end

    test "featured card uses coach recommendation when history is available", %{
      conn: conn,
      user: user
    } do
      plan = plan_fixture(user, %{"name" => "Stored Plan", "burpee_type" => "six_count"})

      for _ <- 1..5 do
        session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 180
        })
      end

      {:ok, view, _html} = live(conn, ~p"/workouts")

      assert has_element?(view, "#workouts-featured-card[data-featured-source='coach']")
      assert render(view) =~ "Recommended today"
      assert has_element?(view, "#workouts-featured-card a[href^='/workouts/new?']")
    end

    test "Workouts page does not render a floating new-plan action", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, _view, html} = live(conn, ~p"/workouts")

      refute html =~ ~s(id="workouts-floating-new-plan")
    end

    test "Mine filter shows only plans", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      refute html =~ "BDT Video"
    end

    test "Videos filter shows only videos", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='videos']") |> render_click()

      html = render(view)
      refute html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "clicking active source filter deselects it", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "type filter restricts list", %{conn: conn, user: user} do
      _six = plan_fixture(user, %{"name" => "Six plan", "burpee_type" => "six_count"})
      _seal = plan_fixture(user, %{"name" => "SEAL plan", "burpee_type" => "navy_seal"})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-burpee_type='six_count']") |> render_click()

      html = render(view)
      assert html =~ "Six plan"
      refute html =~ "SEAL plan"
    end

    test "Mine empty state shows when user has no plans", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert render(view) =~ "have not built any plans"
    end

    test "filter state reflected in URL", %{conn: conn, user: user} do
      _plan = plan_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert_patch(view, "/workouts?source=mine")
    end

    test "plan card opens editor and exposes an explicit play button", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts")

      assert has_element?(view, "#workout-card-plan-#{plan.id}[href='/workouts/#{plan.id}/edit']")
      assert has_element?(view, "#workout-play-plan-#{plan.id}[href='/session/#{plan.id}']")
    end

    test "prescription timeline renders block nodes with timing", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Timeline Plan"})
      {:ok, _view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ ~s(id="plan-prescription-timeline")
      assert html =~ ~s(data-timeline-block-node)
      assert html =~ "0:00"
      assert html =~ "Block 1"
      assert html =~ "3 sets"
      assert html =~ "4:00"
    end

    test "block timeline node expands set children and edits a set", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Timeline Edit Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("[data-timeline-row-index='1'][data-timeline-block-node]") |> render_click()

      assert has_element?(view, "[data-timeline-set-node]")
      assert has_element?(view, "[data-timeline-set-editor]")
      html = render(view)
      assert html =~ "Set 1"
      assert html =~ "Reps"
      assert html =~ "Pace"
      assert html =~ "Recovery"

      view
      |> element("[data-timeline-set-editor='0-0']")
      |> render_change(%{
        "set" => %{
          "block_index" => "0",
          "set_index" => "0",
          "burpee_count" => "12",
          "sec_per_rep" => "5.5",
          "end_of_set_rest" => "20"
        }
      })

      html = render(view)
      assert html =~ "Set 1"
      assert html =~ "12 reps"
      assert html =~ "5.50s/rep"
      assert html =~ "20s recovery"
    end

    test "timeline add rest handle injects editable rest node", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      assert has_element?(view, "[data-timeline-edge-action]")

      view
      |> element("[data-timeline-edge-index='0'][data-timeline-edge-action]")
      |> render_click()

      assert has_element?(view, "[data-timeline-rest-node]")
      assert has_element?(view, "[data-timeline-rest-editor]")
      assert has_element?(view, "[data-timeline-remove-rest]")
      html = render(view)
      assert html =~ "+30s recovery"
      assert html =~ "at minute"

      view
      |> element("[data-timeline-rest-editor]")
      |> render_change(%{"rest" => %{"index" => "0", "rest_sec" => "45", "target_min" => "8"}})

      html = render(view)
      assert html =~ "+45s recovery"
      assert html =~ "at minute 8"

      view |> element("[data-timeline-remove-rest]") |> render_click()
      refute render(view) =~ "+45s recovery"
    end

    test "fine tune groups equal sets before expanding details", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Grouped Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("button", "Show structure") |> render_click()
      html = render(view)

      assert has_element?(view, "[data-grouped-set-row]")
      assert html =~ "2 sets"
      assert html =~ "10 reps"
      assert html =~ "30s rest"
      refute html =~ "+ Add set"

      view |> element("button", "Adjust sets") |> render_click()
      expanded_html = render(view)
      assert expanded_html =~ "Set 1"
      assert expanded_html =~ "+ Add set"
    end

    test "plan edit page exposes duplicate and delete actions", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#plan-duplicate")
      assert has_element?(view, "#plan-delete")
    end

    test "copying a plan from the edit page opens the copied plan", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("#plan-duplicate") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r"/workouts/\d+/edit"
      refute path == "/workouts/#{plan.id}/edit"
    end

    test "deleting a plan from the edit page returns to workouts", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("#plan-delete") |> render_click()

      assert_redirect(view, "/workouts")
    end

    test "video card has no edit link", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})
      {:ok, _view, html} = live(conn, ~p"/workouts")

      refute html =~ ~r"/workouts/\d+/edit"
    end
  end

  describe "/workouts/new" do
    test "renders the new plan editor surface", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts/new")

      assert html =~ "session-surface"
      assert html =~ ~s(id="plan-form")
      assert html =~ "Custom session"
      assert html =~ "Type"
      assert html =~ "Duration"
      assert html =~ "Goal"
      assert html =~ "Style"
      assert html =~ "Prescription"
      assert html =~ "Predicted"
      assert html =~ "Show structure"
      assert html =~ ~s(id="plan-prescription-timeline")
      assert html =~ ~s(data-timeline-primary-graph)
      assert html =~ ~s(data-timeline-edge)
      assert html =~ "left-[5.625rem]"
      assert html =~ ~s(data-timeline-edge-action)
      assert html =~ ~s(data-timeline-block-node)
      assert html =~ "Start"
      assert html =~ "Finish"
      assert html =~ "Six-Count"
      assert html =~ "Navy SEAL"
      assert html =~ "Create session"
      refute html =~ ">Reps<"
      refute html =~ ">Pace<"
    end

    test "advanced keeps block language without splitting into nested cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("button", "Show structure") |> render_click()

      html = render(view)
      assert html =~ "Block 1"
      assert html =~ "Set 1"
      assert html =~ "Structure"
      assert html =~ "Inspect block details"
      assert html =~ "Rest plan"
      assert html =~ "No planned rests"
      assert has_element?(view, "#plan-fine-tune-panel")
      assert has_element?(view, "#fine-tune-rests")
      refute html =~ "Segment 1"
      refute html =~ ">Cadence<"
      refute html =~ ">Rest [s]<"
      refute html =~ ~s(data-fine-tune-card)
    end

    test "picking Navy SEAL keeps the editor rendered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("button[phx-click='pick_type'][phx-value-type='navy_seal']")
      |> render_click()

      html = render(view)
      assert html =~ "Navy SEAL"
      assert html =~ ~s(id="plan-form")
    end
  end
end
