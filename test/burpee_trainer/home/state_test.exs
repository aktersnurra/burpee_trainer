defmodule BurpeeTrainer.Home.StateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Home.{Facts, State}

  defp facts_gen do
    gen all(
          home_state <- member_of([:workout_needed, :done_today, :week_complete]),
          started_id <- one_of([constant(nil), positive_integer()]),
          selection_id <- one_of([constant(nil), positive_integer()]),
          result_id <- positive_integer()
        ) do
      started = if is_nil(started_id), do: nil, else: %{id: started_id, token: result_id}
      selection = if is_nil(selection_id), do: nil, else: %{plan: %{id: selection_id}}
      results = %{today: [%{id: result_id}], week: [%{id: result_id + 1}]}

      facts(home_state, started, selection, results)
    end
  end

  property "generated facts derive their exact state payload and exactly one primary action" do
    check all(facts <- facts_gen()) do
      expected = expected_state(facts)

      assert State.derive(facts) == expected
      assert State.primary_action(State.derive(facts)) == expected_action(expected)

      assert State.primary_action(State.derive(facts)) in [:resume, :start, :choose, :insights]
    end
  end

  property "a started session always wins contradictory facts" do
    check all(facts <- facts_gen()) do
      facts = %{facts | started_session: %{id: 9}}
      assert {:resume, %{id: 9}} = State.derive(facts)
      assert :resume = facts |> State.derive() |> State.primary_action()
    end
  end

  test "all five derived states map to their one primary action" do
    states = [
      {{:resume, %{id: 1}}, :resume},
      {{:start, %{plan: %{id: 2}}}, :start},
      {:choose, :choose},
      {{:done_today, %{}}, :insights},
      {{:week_complete, %{}}, :insights}
    ]

    for {state, action} <- states do
      assert State.primary_action(state) == action
    end
  end

  test "workout needed with a selection starts it" do
    facts = facts(:workout_needed, nil, %{plan: %{id: 2}})
    assert {:start, %{plan: %{id: 2}}} = State.derive(facts)
  end

  test "workout needed without a selection asks to choose" do
    assert :choose = State.derive(facts(:workout_needed, nil, nil))
  end

  test "done today and week complete beat a selection" do
    assert {:done_today, %{today: []}} =
             State.derive(facts(:done_today, nil, %{plan: %{id: 2}}, %{today: []}))

    assert {:week_complete, %{week: []}} =
             State.derive(facts(:week_complete, nil, %{plan: %{id: 2}}, %{week: []}))
  end

  defp expected_state(%Facts{started_session: %{} = session}), do: {:resume, session}

  defp expected_state(%Facts{slot: %{home_state: :done_today}, results: results}),
    do: {:done_today, results}

  defp expected_state(%Facts{slot: %{home_state: :week_complete}, results: results}),
    do: {:week_complete, results}

  defp expected_state(%Facts{selection: %{} = selection}), do: {:start, selection}
  defp expected_state(%Facts{}), do: :choose

  defp expected_action({:resume, _}), do: :resume
  defp expected_action({:start, _}), do: :start
  defp expected_action(:choose), do: :choose
  defp expected_action({state, _}) when state in [:done_today, :week_complete], do: :insights

  defp facts(home_state, started, selection, results \\ %{}) do
    %Facts{
      slot: %{home_state: home_state},
      started_session: started,
      selection: selection,
      results: results
    }
  end
end
