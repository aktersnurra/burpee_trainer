defmodule BurpeeTrainerWeb.OidcControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainer.Repo

  defmodule StubOidc do
    @behaviour BurpeeTrainer.Auth.Oidc

    @impl true
    def authorization_url(state, _verifier) do
      {:ok, "https://pocket-id.test/authorize?state=#{state}"}
    end

    @impl true
    def fetch_claims("good-code", _verifier), do: {:ok, %{"sub" => "sub-abc-123"}}
    def fetch_claims("unknown-code", _verifier), do: {:ok, %{"sub" => "sub-nobody"}}
    def fetch_claims("other-code", _verifier), do: {:ok, %{"sub" => "sub-other"}}
    def fetch_claims(_code, _verifier), do: {:error, :invalid_grant}
  end

  setup do
    Application.put_env(:burpee_trainer, :oidc_module, StubOidc)
    on_exit(fn -> Application.delete_env(:burpee_trainer, :oidc_module) end)
    :ok
  end

  describe "GET /auth/oidc" do
    test "redirects to the provider and stores state in the session", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc")

      assert redirected_to(conn) =~ "https://pocket-id.test/authorize"
      assert get_session(conn, :oidc_state)
      assert get_session(conn, :oidc_pkce_verifier)
    end
  end

  describe "GET /auth/oidc/callback" do
    test "logs in the user whose oidc_sub matches the claim", %{conn: conn} do
      user = user_fixture(%{"username" => "alice"})
      {:ok, user} = Accounts.link_oidc_sub(user, "sub-abc-123")

      conn =
        conn
        |> init_test_session(%{oidc_state: "st", oidc_pkce_verifier: "vf"})
        |> get(~p"/auth/oidc/callback", %{"code" => "good-code", "state" => "st"})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id) == user.id
    end

    test "rejects an unknown sub and creates no user", %{conn: conn} do
      _user = user_fixture(%{"username" => "alice"})
      before_count = Repo.aggregate(Accounts.User, :count)

      conn =
        conn
        |> init_test_session(%{oidc_state: "st", oidc_pkce_verifier: "vf"})
        |> get(~p"/auth/oidc/callback", %{"code" => "unknown-code", "state" => "st"})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
      assert Repo.aggregate(Accounts.User, :count) == before_count
    end

    test "logs in the matching user, not merely the first user", %{conn: conn} do
      alice = user_fixture(%{"username" => "alice"})
      bob = user_fixture(%{"username" => "bob"})
      {:ok, _} = Accounts.link_oidc_sub(alice, "sub-abc-123")
      {:ok, bob} = Accounts.link_oidc_sub(bob, "sub-other")

      conn =
        conn
        |> init_test_session(%{oidc_state: "st", oidc_pkce_verifier: "vf"})
        |> get(~p"/auth/oidc/callback", %{"code" => "other-code", "state" => "st"})

      assert get_session(conn, :user_id) == bob.id
    end

    test "rejects a mismatched state (CSRF)", %{conn: conn} do
      user = user_fixture(%{"username" => "alice"})
      {:ok, _} = Accounts.link_oidc_sub(user, "sub-abc-123")

      conn =
        conn
        |> init_test_session(%{oidc_state: "expected", oidc_pkce_verifier: "vf"})
        |> get(~p"/auth/oidc/callback", %{"code" => "good-code", "state" => "attacker"})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end

    test "rejects a callback with no state in the session", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "good-code", "state" => "st"})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end

    test "rejects a provider error response", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{oidc_state: "st", oidc_pkce_verifier: "vf"})
        |> get(~p"/auth/oidc/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end

    test "rejects a failed token exchange", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{oidc_state: "st", oidc_pkce_verifier: "vf"})
        |> get(~p"/auth/oidc/callback", %{"code" => "bad-code", "state" => "st"})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end
  end
end
