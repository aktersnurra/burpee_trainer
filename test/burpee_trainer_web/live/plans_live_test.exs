defmodule BurpeeTrainerWeb.PlansLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/plans" do
    test "empty state renders when no plans exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plans")
      assert html =~ "No plans yet"
    end

    test "lists existing plans with summary", %{conn: conn, user: user} do
      _ = plan_fixture(user, %{"name" => "Morning grind"})
      {:ok, _view, html} = live(conn, ~p"/plans")

      assert html =~ "Morning grind"
      assert html =~ "6-count"
    end

    test "deleting a plan removes it", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Doomed"})
      {:ok, view, _} = live(conn, ~p"/plans")

      view |> element("button[phx-click='delete'][phx-value-id='#{plan.id}']") |> render_click()

      refute render(view) =~ "Doomed"
      assert Workouts.list_plans(user) == []
    end

    test "duplicating a plan creates a copy", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Original"})
      {:ok, view, _} = live(conn, ~p"/plans")

      view
      |> element("button[phx-click='duplicate'][phx-value-id='#{plan.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Original"
      assert html =~ "Original (copy)"
    end
  end

  describe "/plans/new" do
    test "mounts with a default block + sets and renders the summary sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plans/new")

      assert html =~ "New plan"
      assert html =~ "Block 1"
      assert html =~ "Summary"
    end

    test "validates name is required", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/plans/new")

      html =
        view
        |> form("#plan-form", workout_plan: %{"name" => ""})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "saves a valid plan and navigates to edit", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/plans/new")

      params = %{
        "name" => "Built in test",
        "burpee_type" => "six_count",
        "warmup_enabled" => "false",
        "blocks" => %{
          "0" => %{
            "position" => "1",
            "repeat_count" => "2",
            "sets" => %{
              "0" => %{
                "position" => "1",
                "burpee_count" => "5",
                "sec_per_rep" => "6.0",
                "sec_per_burpee" => "3.0",
                "duration_min" => "1"
              },
              "1" => %{
                "position" => "2",
                "burpee_count" => "5",
                "sec_per_rep" => "6.0",
                "sec_per_burpee" => "3.0",
                "duration_min" => "1"
              }
            }
          }
        }
      }

      assert view
             |> form("#plan-form", workout_plan: params)
             |> render_submit()
             |> follow_redirect(conn)

      assert [plan] = Workouts.list_plans(user)
      assert plan.name == "Built in test"
      assert plan.burpee_type == :six_count
    end
  end

  describe "/plans/:id/edit" do
    test "edits an existing plan and updates persist", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Old name"})
      {:ok, view, html} = live(conn, ~p"/plans/#{plan.id}/edit")

      assert html =~ "Old name"

      params = %{
        "name" => "Renamed",
        "burpee_type" => "six_count",
        "warmup_enabled" => "false",
        "blocks" => %{
          "0" => %{
            "position" => "1",
            "repeat_count" => "1",
            "sets" => %{
              "0" => %{
                "position" => "1",
                "burpee_count" => "7",
                "sec_per_rep" => "6.0",
                "sec_per_burpee" => "3.0",
                "duration_min" => "1"
              }
            }
          }
        }
      }

      view
      |> form("#plan-form", workout_plan: params)
      |> render_submit()

      assert Workouts.get_plan!(user, plan.id).name == "Renamed"
    end

    test "cannot edit a plan belonging to another user", %{conn: conn, user: _user} do
      other = user_fixture()
      plan = plan_fixture(other)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/plans/#{plan.id}/edit")
      end
    end
  end
end
