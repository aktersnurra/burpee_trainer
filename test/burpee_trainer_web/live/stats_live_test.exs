defmodule BurpeeTrainerWeb.StatsLiveTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainerWeb.StatsLive

  test "load more consumes the compound cursor and appends the next database page once" do
    user = user_fixture()
    completed_at = ~U[2025-09-01 12:00:00Z]

    sessions =
      for count <- 1..7 do
        free_form_session_fixture(user, %{
          "burpee_count_actual" => count,
          "completed_at" => completed_at
        })
      end

    {first_page, true} = Workouts.list_sessions_page(user, 5)
    cursor = first_page |> List.last() |> then(&{&1.completed_at, &1.id})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: user,
        period_start: nil,
        sessions: first_page,
        sessions_cursor: cursor,
        sessions_has_more: true,
        sessions_visible_count: 5
      }
    }

    assert {:noreply, updated_socket} =
             StatsLive.handle_event("load_more_sessions", %{}, socket)

    expected_ids = sessions |> Enum.map(& &1.id) |> Enum.sort(:desc)
    actual_ids = Enum.map(updated_socket.assigns.sessions, & &1.id)

    assert actual_ids == expected_ids
    assert Enum.uniq(actual_ids) == actual_ids
    refute updated_socket.assigns.sessions_has_more
  end
end
