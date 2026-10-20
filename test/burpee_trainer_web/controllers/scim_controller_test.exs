defmodule BurpeeTrainerWeb.ScimControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Accounts, Repo}

  # The requests Pocket ID v2.16 sends (backend/internal/scimsync/service.go): paged lists,
  # then POST, PUT and DELETE with `application/scim+json` bodies and a Bearer token.
  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"

  setup %{conn: conn} do
    previous = Application.get_env(:burpee_trainer, :scim)
    Application.put_env(:burpee_trainer, :scim, token: "scim-secret", coach_group: "pid-coach")
    on_exit(fn -> Application.put_env(:burpee_trainer, :scim, previous) end)
    %{conn: conn}
  end

  defp scim(conn, method, path, body \\ nil, token \\ "scim-secret") do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/scim+json")
    |> then(fn conn ->
      if body,
        do: conn |> put_req_header("content-type", "application/scim+json"),
        else: conn
    end)
    |> dispatch(@endpoint, method, path, body && Jason.encode!(body))
  end

  defp body(conn, status) do
    assert conn.status == status, "got #{conn.status}: #{conn.resp_body}"
    if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
  end

  defp user_payload(sub, username, active \\ true) do
    %{
      "schemas" => [@user_schema],
      "externalId" => sub,
      "userName" => username,
      "name" => %{"givenName" => "A", "familyName" => "B"},
      "displayName" => username,
      "active" => active,
      "emails" => [%{"value" => "#{username}@example.com", "primary" => true}]
    }
  end

  defp group_payload(external_id, member_ids) do
    %{
      "schemas" => [@group_schema],
      "externalId" => external_id,
      "displayName" => "Burpee coach",
      "members" => Enum.map(member_ids, &%{"value" => to_string(&1)})
    }
  end

  defp linked_user(username, sub) do
    {:ok, user} = Accounts.link_oidc_sub(user_fixture(%{"username" => username}), sub)
    user
  end

  test "/scim/v2 is off without a token, and refuses a wrong one", %{conn: conn} do
    assert conn |> scim(:get, "/scim/v2/Users", nil, "wrong") |> body(401)

    Application.put_env(:burpee_trainer, :scim, [])
    assert conn |> scim(:get, "/scim/v2/Users") |> response(404)
  end

  test "a sync provisions users and groups, and the coach group decides the coach",
       %{conn: conn} do
    alice = linked_user("alice", "pid-alice")
    _unlinked = user_fixture(%{"username" => "legacy"})

    # Only users Pocket ID knows are listed; never written over SCIM, so no lastModified.
    listed = conn |> scim(:get, "/scim/v2/Users?startIndex=1&count=1000") |> body(200)
    assert listed["totalResults"] == 1

    assert [%{"externalId" => "pid-alice", "active" => true, "meta" => meta}] =
             listed["Resources"]

    refute Map.has_key?(meta, "lastModified")

    assert conn
           |> scim(:put, "/scim/v2/Users/#{alice.id}", user_payload("pid-alice", "alice"))
           |> body(200)

    bob = conn |> scim(:post, "/scim/v2/Users", user_payload("pid-bob", "bob")) |> body(201)
    assert %{"externalId" => "pid-bob", "userName" => "bob", "active" => true} = bob
    assert bob["meta"]["lastModified"]

    assert conn
           |> scim(:get, "/scim/v2/Groups?startIndex=1&count=1000")
           |> body(200)
           |> Map.get("totalResults") == 0

    group =
      conn
      |> scim(:post, "/scim/v2/Groups", group_payload("pid-coach", [bob["id"]]))
      |> body(201)

    assert %{"externalId" => "pid-coach", "members" => [%{"value" => bob_id}]} = group
    assert bob_id == bob["id"]
    assert Accounts.get_user(alice.id).coach == :mcp
    assert Accounts.get_user(String.to_integer(bob["id"])).coach == :app

    # Alice joins the coach group in Pocket ID.
    conn
    |> scim(
      :put,
      "/scim/v2/Groups/#{group["id"]}",
      group_payload("pid-coach", [bob["id"], alice.id])
    )
    |> body(200)

    assert Accounts.get_user(alice.id).coach == :app

    # Another allowed group changes no one's coach.
    conn |> scim(:post, "/scim/v2/Groups", group_payload("pid-burpee", [alice.id])) |> body(201)
    assert Accounts.get_user(String.to_integer(bob["id"])).coach == :app

    # The coach group no longer reaches the app: nobody has the app's coach.
    assert conn |> scim(:delete, "/scim/v2/Groups/#{group["id"]}") |> body(204) == nil
    assert Accounts.get_user(alice.id).coach == :mcp
  end

  test "blocking a user ends their access, and closes the pages they have open",
       %{conn: conn} do
    user = linked_user("alice", "pid-alice")
    browser = init_test_session(conn, %{user_id: user.id})
    {:ok, _view, _html} = live(browser, ~p"/")

    # The browser's socket listens on its live_socket_id; a "disconnect" there closes it.
    live_socket_id = browser |> get(~p"/") |> get_session(:live_socket_id)
    BurpeeTrainerWeb.Endpoint.subscribe(live_socket_id)

    blocked =
      conn
      |> scim(:put, "/scim/v2/Users/#{user.id}", user_payload("pid-alice", "alice", false))
      |> body(200)

    assert blocked["active"] == false
    assert Accounts.get_user(user.id).access == :disabled
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:error, {:redirect, %{to: "/login"}}} = live(browser, ~p"/")

    conn
    |> scim(:put, "/scim/v2/Users/#{user.id}", user_payload("pid-alice", "alice"))
    |> body(200)

    assert {:ok, _view, _html} = live(browser, ~p"/")
  end

  test "deleting a user keeps their history, and creating them again restores it",
       %{conn: conn} do
    user = linked_user("alice", "pid-alice")
    session = free_form_session_fixture(user)

    assert conn |> scim(:delete, "/scim/v2/Users/#{user.id}") |> body(204) == nil
    assert Accounts.get_user(user.id).access == :removed

    assert BurpeeTrainer.Workouts.get_session(
             BurpeeTrainer.Accounts.Scope.for_user(user),
             session.id
           )

    # Gone as a resource: not listed, not found, and a second delete is a 404 Pocket ID accepts.
    assert conn |> scim(:get, "/scim/v2/Users") |> body(200) |> Map.get("totalResults") == 0
    assert conn |> scim(:get, "/scim/v2/Users/#{user.id}") |> body(404)
    assert conn |> scim(:delete, "/scim/v2/Users/#{user.id}") |> body(404)

    restored =
      conn |> scim(:post, "/scim/v2/Users", user_payload("pid-alice", "alice")) |> body(201)

    assert restored["id"] == to_string(user.id)
    assert Accounts.get_user(user.id).access == :active
  end

  test "a username held by another identity is a conflict, not a takeover", %{conn: conn} do
    owner = linked_user("alice", "pid-alice")

    assert conn
           |> scim(:post, "/scim/v2/Users", user_payload("pid-impostor", "alice"))
           |> body(409)
           |> Map.get("scimType") == "uniqueness"

    assert Repo.reload!(owner).oidc_sub == "pid-alice"
  end
end
