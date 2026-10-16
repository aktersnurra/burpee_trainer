defmodule BurpeeTrainerWeb.CoachPermissionFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Coach, Mcp, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Client, Summary}

  defp without_coach(user),
    do: user |> Ecto.Changeset.change(coach_enabled: false) |> Repo.update!()

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    %{conn: conn, user: user}
  end

  test "the app never calls the model for a user without the coach", %{user: user} do
    previous = Application.get_env(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, previous) end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "k",
      model: "m"
    )

    scope = Scope.for_user(without_coach(user))
    refute Coach.enabled?(scope)
    assert Coach.enabled?(Scope.for_user(Map.put(user, :coach_enabled, true)))

    ledger = %{scope: scope, purpose: "summary", run_id: Ecto.UUID.generate()}
    assert {:error, %{code: :provider_unavailable}} = Client.chat([], ledger: ledger)
    assert llm_call_count(scope) == 0
  end

  test "Home without the coach shows Claude's note and this week, with no message box",
       %{conn: conn, user: user} do
    user = without_coach(user)
    scope = Scope.for_user(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:reply, %{"result" => %{"isError" => false}}} =
      Mcp.handle(scope, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "set_coach_note",
          "arguments" => %{
            "text" => "Two sessions left; keep Thursday easy.",
            "review" => "Six-count held steady this week."
          }
        }
      })

    assert Summary.get(scope).source == :claude

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-note", "Two sessions left; keep Thursday easy.")
    assert has_element?(view, "#home-coach-week")
    refute has_element?(view, "#home-coach-message-form")
    refute has_element?(view, ".coach-quick-replies")
  end

  test "Home without the coach and nothing from Claude has no coach section",
       %{conn: conn, user: user} do
    user = without_coach(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    refute has_element?(view, "#home-coach-panel")
  end

  test "with the coach, Home still has the conversation", %{conn: conn, user: user} do
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-message-form")
  end

  test "set_coach_note refuses what the athlete should not read", %{user: user} do
    scope = Scope.for_user(user)

    for arguments <- [
          %{"text" => ""},
          %{"text" => String.duplicate("long ", 100)},
          %{"text" => "Your level_1b is near."},
          %{"text" => "Fine.", "extra" => 1}
        ] do
      {:reply, %{"result" => result}} =
        Mcp.handle(scope, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "set_coach_note", "arguments" => arguments}
        })

      assert result["isError"], "kept #{inspect(arguments)}"
    end

    assert Summary.get(scope) == nil
  end
end
