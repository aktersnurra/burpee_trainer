defmodule BurpeeTrainerWeb.HomeChooseRecoveryTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Notebook
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession, WorkoutVideo}

  setup %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(user, %{target_reps: 10})
    foreign = plan_fixture(user_fixture(), %{target_reps: 10})
    archived = plan_fixture(user, %{target_reps: 10})
    {:ok, archived} = Workouts.archive_plan(Scope.for_user(user), archived.id)
    video = video_fixture(%{burpee_count: 10, duration_sec: 120})
    unavailable = video_fixture(%{available: false, burpee_count: 10, duration_sec: 120})

    # Real absent fallback, not a forged selection or a first-use authorization.
    Repo.update_all(from(p in WorkoutPlan, where: is_nil(p.user_id) and p.origin == :built_in),
      set: [state: :archived, archived_at: DateTime.utc_now(:second)]
    )

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-page[data-home-state=choose]")
    assert :sys.get_state(view.pid).socket.assigns.home_selection == nil

    %{
      view: view,
      user: user,
      plan: plan,
      foreign: foreign,
      archived: archived,
      video: video,
      unavailable: unavailable
    }
  end

  test "real choose reads and filters expose actual catalog rows without writes", context do
    %{
      view: view,
      plan: plan,
      foreign: foreign,
      archived: archived,
      video: video,
      unavailable: unavailable
    } = context

    before = persisted()

    view |> element("#home-title-action[data-primary-action=choose]") |> render_click()

    assert has_element?(
             view,
             "#home-alternatives-panel[role=dialog][aria-modal=true]:not([hidden])"
           )

    assert has_element?(
             view,
             "#home-alternative-plan-#{plan.id}-select:not([disabled])[phx-value-id='#{plan.id}'][phx-value-kind=plan]"
           )

    refute has_element?(view, "#home-alternative-plan-#{foreign.id}-select")
    refute has_element?(view, "#home-alternative-plan-#{archived.id}-select")
    view |> element("#home-filter-toggle") |> render_click()
    selected = has_element?(view, "#home-type-six_count[aria-pressed=true]")
    view |> element("#home-type-six_count") |> render_click()
    assert has_element?(view, "#home-type-six_count[aria-pressed=#{not selected}]")
    view |> element("#home-filter-reset") |> render_click()
    assert has_element?(view, "#home-alternative-plan-#{plan.id}-select")
    view |> element("#home-tab-videos") |> render_click()
    assert has_element?(view, "#home-alternative-video-#{video.id}-select:not([disabled])")
    refute has_element?(view, "#home-alternative-video-#{unavailable.id}-select")
    view |> element("#home-alternatives-panel") |> render_keydown(%{"key" => "Escape"})
    assert has_element?(view, "#home-alternatives-panel[hidden]")
    assert persisted() == before
  end

  test "choose catalog streams replay across all three actions with filters and unsent Coach text",
       %{view: view, user: user, plan: plan} do
    before = persisted()
    pid = view.pid
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()
    render_click(view, "filter", %{"kind" => "type", "filter" => "navy_seal"})
    filters = :sys.get_state(view.pid).socket.assigns.filters

    for _ <- 1..2 do
      view |> element("#home-history-toggle") |> render_click()
      assert_patch(view, "/progress")
      assert has_element?(view, "#home-history-heading[tabindex='-1'][phx-mounted]")
      render_patch(view, ~p"/coach")

      view
      |> form("#home-coach-message-form", coach_message: %{text: "Keep this unsent"})
      |> render_change()

      view |> element("#history-coach-summary") |> render_click()
      assert_patch(view, "/progress")
      view |> element("#home-history-close") |> render_click()
      assert_patch(view, "/")
      assert view.pid == pid
      assert has_element?(view, "#home-page[data-home-state=choose]")
      assert has_element?(view, "#home-alternative-plan-#{plan.id}-select")
      assert :sys.get_state(view.pid).socket.assigns.filters == filters

      assert :sys.get_state(view.pid).socket.assigns.coach_message_form[:text].value ==
               "Keep this unsent"

      assert Notebook.get(Scope.for_user(user)).body == ""
      assert persisted() == before
    end
  end

  test "explicit real choose plan activation recovers a Start selection", %{
    view: view,
    plan: plan,
    user: user
  } do
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-alternative-plan-#{plan.id}-select") |> render_click()

    assert has_element?(
             view,
             "#home-page[data-home-state=start] #home-action[data-primary-action=start]"
           )

    assert :sys.get_state(view.pid).socket.assigns.home_selection.plan.id == plan.id
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    selected = :sys.get_state(view.pid).socket.assigns.home_selection
    view |> element("#home-action") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    assert started.plan_id == plan.id
    assert started.content_hash == selected.plan.content_hash
    assert_redirect(view, ~p"/session/#{started.id}")
  end

  test "explicit real choose video activation starts the canonical video", %{
    view: view,
    video: video,
    user: user
  } do
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-tab-videos") |> render_click()
    before = :sys.get_state(view.pid).socket.assigns
    view |> element("#home-alternative-video-#{video.id}-select") |> render_click()

    assert %{workout_video_id: video_id} =
             started = Workouts.current_started_session(Scope.for_user(user))

    assert video_id == video.id
    assert_redirect(view, ~p"/videos/#{video.id}/session/#{started.id}")
    rows = persisted()

    assert {:ok, replayed} =
             Workouts.start_recovery_home_video(
               Scope.for_user(user),
               before.slot,
               video.id,
               before.start_client_session_id
             )

    assert replayed.id == started.id
    assert replayed.content_hash == started.content_hash
    assert replayed.video_snapshot == started.video_snapshot

    assert {:error, _} =
             Workouts.start_recovery_home_video(
               Scope.for_user(user),
               before.slot,
               video.id,
               Ecto.UUID.generate()
             )

    assert persisted() == rows
  end

  test "forged foreign archived and unavailable recovery clicks never write", context do
    rows = persisted()

    for {kind, id} <- [
          {"plan", context.foreign.id},
          {"plan", context.archived.id},
          {"video", context.unavailable.id}
        ] do
      render_click(context.view, "select_alternative", %{"kind" => kind, "id" => to_string(id)})
      assert persisted() == rows
      assert has_element?(context.view, "#home-page[data-home-state=choose]")
    end
  end

  test "an independently recovered winner is not replaced by the stale mounted chooser",
       context do
    slot = :sys.get_state(context.view.pid).socket.assigns.slot
    winner = plan_fixture(context.user, %{target_reps: 10, name: "Winning choice"})

    assert {:ok, selected} =
             Workouts.recover_home_workout_selection(
               Scope.for_user(context.user),
               slot,
               winner.id
             )

    rows = persisted()

    render_click(context.view, "select_alternative", %{
      "kind" => "plan",
      "id" => to_string(context.plan.id)
    })

    assert persisted() == rows
    assert Workouts.current_home_selection(Scope.for_user(context.user), slot) == selected
    assert has_element?(context.view, "#home-page[data-home-state=choose]")
  end

  test "nil-selection owned Delete reports actual absent-fallback rejection without effects",
       %{view: view, plan: plan, user: user} do
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()

    assert has_element?(
             view,
             "#home-delete-workout-#{plan.id}[phx-click=delete_workout][data-confirm='Delete this workout? Past sessions will be kept.']"
           )

    before_rows = all_table_rows()
    before_assigns = stable_assigns(view)
    view |> element("#home-delete-workout-#{plan.id}") |> render_click()

    assert has_element?(
             view,
             "#home-alternatives-panel:not([hidden]) #home-chooser-error[role=alert]",
             "That workout could not be deleted. Your history is unchanged."
           )

    assert all_table_rows() == before_rows
    assert stable_assigns(view) == before_assigns
    assert Repo.get!(WorkoutPlan, plan.id).state == :published
    assert Workouts.current_home_selection(Scope.for_user(user), before_assigns.slot) == nil

    view |> element("#home-type-six_count") |> render_click()
    assert stable_assigns(view).filters != before_assigns.filters
    view |> element("#home-filter-reset") |> render_click()
    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/progress")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    view |> element("#home-alternatives-panel") |> render_keydown(%{"key" => "Escape"})
    assert has_element?(view, "#home-alternatives-panel[hidden]")
    view |> element("#home-title-action") |> render_click()
    assert all_table_rows() == before_rows
    view |> element("#home-alternative-plan-#{plan.id}-select") |> render_click()
    selected = stable_assigns(view).home_selection
    assert selected.plan.id == plan.id
    view |> element("#home-action") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    assert started.plan_id == plan.id
    assert started.content_hash == selected.plan.content_hash
    assert_redirect(view, ~p"/session/#{started.id}")
  end

  test "nil-selection foreign and archived Delete preserve all rows and workspace assigns",
       %{view: view, foreign: foreign, archived: archived} do
    view |> element("#home-title-action") |> render_click()
    before_rows = all_table_rows()
    before_assigns = stable_assigns(view)

    for id <- [foreign.id, archived.id] do
      render_click(view, "delete_workout", %{"id" => to_string(id)})

      assert has_element?(
               view,
               "#home-alternatives-panel:not([hidden]) #home-chooser-error[role=alert]",
               "That workout could not be deleted. Your history is unchanged."
             )

      assert all_table_rows() == before_rows
      assert stable_assigns(view) == before_assigns
    end
  end

  test "each actual chooser rejection requests local focus and scroll without effects", %{
    view: view,
    plan: plan
  } do
    view |> element("#home-title-action") |> render_click()
    before_rows = all_table_rows()
    before_assigns = stable_assigns(view)

    for _ <- 1..2 do
      view |> element("#home-delete-workout-#{plan.id}") |> render_click()
      assert_push_event(view, "home_chooser_rejected", %{})
      assert has_element?(view, "#home-chooser-error[role=alert][tabindex='-1']")
      assert all_table_rows() == before_rows
      assert stable_assigns(view) == before_assigns
    end

    view |> element("#home-alternatives-panel") |> render_keydown(%{"key" => "Escape"})
    render_click(view, "delete_workout", %{"id" => to_string(plan.id)})
    refute_push_event(view, "home_chooser_rejected", %{})
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-history-toggle") |> render_click()
    render_click(view, "delete_workout", %{"id" => to_string(plan.id)})
    refute_push_event(view, "home_chooser_rejected", %{})
  end

  test "guarded busy pending and authoring rejections never request client feedback", %{
    view: view,
    plan: plan
  } do
    view |> element("#home-title-action") |> render_click()
    socket = :sys.get_state(view.pid).socket
    rows = all_table_rows()

    for guard <- [%{busy?: true}, %{pending_request: %{id: "pending"}}, %{authoring_stage: :new}] do
      guarded = %{socket | assigns: Map.merge(socket.assigns, guard)}

      assert {:noreply, rejected} =
               BurpeeTrainerWeb.HomeChooser.handle_event(
                 "delete_workout",
                 %{"id" => to_string(plan.id)},
                 guarded
               )

      assert Phoenix.LiveView.Utils.get_push_events(rejected) == []

      assert Map.drop(rejected.assigns, [:flash, :__changed__]) ==
               Map.drop(guarded.assigns, [:flash, :__changed__])

      assert all_table_rows() == rows
    end
  end

  defp stable_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.drop([:flash, :__changed__])
  end

  defp all_table_rows do
    %{rows: tables} =
      Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")

    for [table] <- tables do
      quoted = String.replace(table, "\"", "\"\"")
      %{columns: columns, rows: rows} = Repo.query!("SELECT * FROM \"#{quoted}\"")
      {table, columns, Enum.sort(rows)}
    end
  end

  defp persisted do
    {Repo.all(WorkoutPlan), Repo.all(WorkoutSession), Repo.all(CoachRecommendation),
     Repo.all(WorkoutVideo), Repo.all(BurpeeTrainer.Coach.Notebook)}
  end
end
