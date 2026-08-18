defmodule BurpeeTrainer.Workouts.SessionPaginationTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  test "compound cursor paginates equal completion timestamps without duplicates or omissions" do
    user = user_fixture()
    completed_at = ~U[2025-09-01 12:00:00Z]

    sessions =
      for count <- 1..3 do
        free_form_session_fixture(user, %{
          "burpee_count_actual" => count,
          "completed_at" => completed_at
        })
      end

    plan = plan_fixture(user)
    {:ok, _started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    {first_page, true} = Workouts.list_sessions_page(user, 2)
    first_cursor = first_page |> List.last() |> then(&{&1.completed_at, &1.id})
    {second_page, false} = Workouts.list_sessions_page(user, 2, before: first_cursor)

    expected_ids = sessions |> Enum.map(& &1.id) |> Enum.sort(:desc)
    actual_ids = Enum.map(first_page ++ second_page, & &1.id)

    assert actual_ids == expected_ids
    assert Enum.uniq(actual_ids) == actual_ids
  end

  test "malformed cursors are rejected without raising" do
    user = user_fixture()

    for cursor <- [DateTime.utc_now(), {DateTime.utc_now(), 0}, {"not-a-date", 1}, :invalid] do
      assert {:error, :invalid_cursor} = Workouts.list_sessions_page(user, 2, before: cursor)
    end
  end
end
