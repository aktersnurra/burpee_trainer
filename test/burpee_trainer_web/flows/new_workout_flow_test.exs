defmodule BurpeeTrainerWeb.Flows.NewWorkoutFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(user, slot)
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    %{conn: conn, view: view, user: user, selected: selected}
  end

  test "New reviews without a plan, approval publishes unselected, then Start completes into History",
       %{
         view: view,
         user: user,
         selected: selected,
         conn: conn
       } do
    definition = %{
      "version" => 1,
      "name" => "Independent new workout",
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "rationale" => "A recorded local provider response.",
      "events" => [%{"kind" => "work", "reps" => 10, "sec_per_rep" => 12, "sec_per_burpee" => 12}]
    }

    counter = fake_authoring_provider(%{"workout_definition" => definition})
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> element("#home-pill-pacing_style-even") |> render_click()
    view |> form("#home-new-form", home_workout: %{reps: 10, duration: "2:00"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#home-new-form[data-stage=review]")
    assert has_element?(view, "#home-new-reps[disabled][value='10']")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert Agent.get(counter, & &1.calls) == ["workout_definition"]

    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-new-saved")
    [saved] = Enum.filter(Workouts.list_library(user), &(&1.name == definition["name"]))
    assert saved.state == :published
    assert Repo.aggregate(WorkoutPlan, :count) == count + 1
    assert {:ok, unchanged} = Workouts.ensure_home_selection(user, selected_slot(user))
    assert unchanged.plan.id == selected.plan.id
    assert Agent.get(counter, & &1.calls) == ["workout_definition"]

    view |> element("#home-new-select") |> render_click()

    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    {:error, {:live_redirect, %{to: "/session/" <> id}}} =
      view |> element("#home-action") |> render_click(%{"client_session_id" => token})

    session = Repo.get!(WorkoutSession, String.to_integer(id))
    assert session.plan_id == saved.id
    {:ok, runner, _} = live(conn, ~p"/session/#{session.id}")

    render_hook(runner, "save_session", %{
      "workout_session" => %{
        "burpee_count_actual" => 10,
        "duration_sec_actual" => 120,
        "client_session_id" => session.client_session_id
      },
      "tracking" => %{"enabled" => false, "trust" => "disabled", "cadence_ms" => []}
    })

    assert_reply(runner, %{status: "ok"})
    {:ok, history, _} = live(conn, ~p"/?history=1")
    assert has_element?(history, "#home-history-session-#{session.id}")
  end

  defp fake_authoring_provider(responses) do
    original = Application.fetch_env!(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, original) end)
    counter = start_supervised!({Agent, fn -> %{responses: responses, calls: []} end})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    start_supervised!(
      {Bandit,
       plug: {BurpeeTrainer.TestAuthoringProviderPlug, counter: counter},
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "http://127.0.0.1:#{port}/chat/completions",
      api_key: "test-key",
      model: "test-model",
      timeout_ms: 20_000
    )

    counter
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    slot
  end
end
