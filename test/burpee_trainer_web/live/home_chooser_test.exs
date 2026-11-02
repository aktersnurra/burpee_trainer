defmodule BurpeeTrainerWeb.HomeChooserTest do
  use BurpeeTrainerWeb.ConnCase

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(user)
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user, plan: plan}
  end

  test "malformed plan ids do not crash selection or archival", %{conn: conn, plan: plan} do
    view = home_view(conn, plan)

    for event <- ["select_alternative", "delete_workout"] do
      render_click(view, event, %{"id" => "not_a_number", "kind" => "plan"})
      assert has_element?(view, "#home-summary")
    end
  end

  defp home_view(conn, plan) do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "select_alternative", %{"id" => to_string(plan.id), "kind" => "plan"})
    view
  end
end
