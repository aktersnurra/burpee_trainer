defmodule BurpeeTrainerWeb.Flows.InsightFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Insights, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Insights.NarrateJob

  setup do
    provider = Application.get_env(:burpee_trainer, :llm_provider)
    defaults = Req.default_options()

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1/chat/completions",
      api_key: "k",
      model: "m"
    )

    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:burpee_trainer, :llm_provider, provider)
      Req.default_options(defaults)
    end)

    :ok
  end

  for {number, expected_source, headline} <- [
        {4, "llm", "Steady progress"},
        {999, "fallback", "Session saved"}
      ] do
    @number number
    @source expected_source
    @headline headline
    test "completed SessionLive -> actual Oban narration -> shared Home/History (#{expected_source})",
         %{conn: conn} do
      # Synthetic Req.Test response, not a claimed real captured provider recording.
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  Jason.encode!(%{
                    "headline" => "Steady progress",
                    "points" => [
                      %{
                        "text" => "#{@number} reps last session.",
                        "metric_ids" => ["session.reps"]
                      }
                    ]
                  })
              }
            }
          ]
        })
      end)

      user = user_fixture()
      {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
      scope = Scope.for_user(user)
      plan = plan_fixture(user)
      {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())
      conn = init_test_session(conn, %{user_id: user.id})
      {:ok, session_view, _} = live(conn, ~p"/session/#{started.id}")

      render_hook(session_view, "save_session", %{
        "workout_session" => %{"burpee_count_actual" => 4, "duration_sec_actual" => 20},
        "tracking" => %{"enabled" => false, "trust" => "disabled", "cadence_ms" => []}
      })

      assert_enqueued(worker: NarrateJob, args: %{user_id: user.id, session_id: started.id})
      assert :ok = perform_job(NarrateJob, %{user_id: user.id, session_id: started.id})
      assert Insights.for_session(scope, started.id).source == @source
      {:ok, home, _} = live(conn, ~p"/")
      assert has_element?(home, "[data-home-state=done_today] #home-insight-headline", @headline)
      pid = home.pid
      home |> element("#home-history-toggle") |> render_click()
      assert_patch(home, "/history")
      home |> element("#home-history-inspect-#{started.id}") |> render_click()
      assert has_element?(home, "#history-insight-points li", "4 reps last session.")
      assert home.pid == pid
    end
  end
end
