defmodule BurpeeTrainerWeb.OverviewRevisionTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Coach.Policy

  test "only loading remains, overlap is ignored, failure restores exact source", %{conn: conn} do
    parent = self()
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)

    on_exit(fn ->
      Req.default_options(previous_req)

      if previous_provider == nil,
        do: Application.delete_env(:burpee_trainer, :llm_provider),
        else: Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
    end)

    Req.default_options(
      adapter: fn request ->
        send(parent, {:provider_waiting, self()})

        receive do
          {:respond, body} -> {request, %Req.Response{status: 200, body: body}}
        end
      end
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "test",
      model: "test"
    )

    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(user, slot)
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()

    render_click(view, "toggle_filters", %{})

    for level <- BurpeeTrainer.Levels.all_levels() do
      selector = "#home-level-#{level}[aria-pressed='false']"

      if has_element?(view, selector),
        do: render_click(view, "filter", %{"kind" => "level", "value" => Atom.to_string(level)})
    end

    assert has_element?(view, "#home-alternative-plan-#{shown.plan.id}")

    [token] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input[name='client_session_id']")
      |> LazyHTML.attribute("value")

    view
    |> form("#home-adjustment-form", home_adjustment: %{instruction: "Less rest"})
    |> render_submit()

    assert_receive {:provider_waiting, worker}
    assert has_element?(view, "#home-update-loading")

    for selector <- ["#home-summary", "#home-inspection", "#home-adjustment-form", "#home-action"] do
      refute has_element?(view, selector)
    end

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => ""}
    })

    assert Workouts.current_started_session(user) == nil
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _}

    send(
      worker,
      {:respond, Jason.encode!(%{"choices" => [%{"message" => %{"content" => "{}"}}]})}
    )

    render_async(view)
    assert has_element?(view, "#home-summary")
    assert has_element?(view, "#home-alternative-plan-#{shown.plan.id}")
    assert has_element?(view, "#home-adjustment", "Less rest")
    assert has_element?(view, "#home-action", "Update")
    assert has_element?(view, "#home-adjustment-error")
    {:ok, after_failure} = Workouts.ensure_home_selection(user, slot)
    assert after_failure.plan.content_hash == shown.plan.content_hash
    assert after_failure.home_revision == shown.home_revision

    view
    |> form("#home-adjustment-form", home_adjustment: %{instruction: "Rename this workout"})
    |> render_submit()

    assert_receive {:provider_waiting, retry_worker}
    definition = Map.put(shown.plan.definition_json, "name", "Revised in Home")

    send(
      retry_worker,
      {:respond,
       Jason.encode!(%{"choices" => [%{"message" => %{"content" => Jason.encode!(definition)}}]})}
    )

    render_async(view)
    assert has_element?(view, "#home-summary", "Revised in Home")
    assert has_element?(view, "#home-action", "Start")
    assert has_element?(view, "#home-expansion[data-open='true']")
    {:ok, revised} = Workouts.ensure_home_selection(user, slot)
    assert revised.home_revision == shown.home_revision + 1
    assert revised.plan.state == :draft
    refute revised.plan.id == shown.plan.id

    [new_token] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input[name='client_session_id']")
      |> LazyHTML.attribute("value")

    refute token == new_token
    assert Workouts.current_started_session(user) == nil
    refute_received {:provider_waiting, _}
  end
end
