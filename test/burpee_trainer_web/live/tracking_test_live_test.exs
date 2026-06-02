defmodule BurpeeTrainerWeb.TrackingTestLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders authenticated tracking test page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/tracking-test")

    assert html =~ "Tracking Test"
    assert html =~ "Camera + pose overlay"
    assert html =~ "BlazePose full"
    assert html =~ ~s(id="pose-debug")
    assert html =~ ~s(phx-hook="PoseDebug")
    assert html =~ "DTW calibration"
    assert html =~ "Start 3s countdown"
    assert html =~ "saves automatically"
    assert html =~ ~s(id="pose-debug-template-start")
    assert html =~ ~s(phx-hook="PoseCalibrationButton")
    assert html =~ ~s(id="pose-debug-trace-start")
    assert html =~ ~s(phx-hook="PoseTraceButton")
    assert html =~ ~s(id="pose-debug-trace-output")
    assert html =~ "Trace recorder"
    assert html =~ "touch-manipulation"
    refute html =~ ~s(id="pose-debug-template-finish")
    assert html =~ ~s(id="pose-debug-dtw-status")
  end
end
