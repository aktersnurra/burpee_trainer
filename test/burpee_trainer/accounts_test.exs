defmodule BurpeeTrainer.AccountsTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts

  describe "get_user_by_oidc_sub/1" do
    test "returns the user with a matching sub" do
      user = user_fixture(%{"username" => "alice"})
      {:ok, user} = Accounts.link_oidc_sub(user, "sub-abc-123")

      assert %{id: id} = Accounts.get_user_by_oidc_sub("sub-abc-123")
      assert id == user.id
    end

    test "returns nil for an unknown sub" do
      _user = user_fixture(%{"username" => "alice"})

      assert Accounts.get_user_by_oidc_sub("sub-nope") == nil
    end

    test "returns nil rather than matching a user with no sub linked" do
      _user = user_fixture(%{"username" => "alice"})

      assert Accounts.get_user_by_oidc_sub(nil) == nil
      assert Accounts.get_user_by_oidc_sub("") == nil
    end
  end

  describe "link_oidc_sub/2" do
    test "writes the sub onto the user" do
      user = user_fixture(%{"username" => "alice"})

      assert {:ok, linked} = Accounts.link_oidc_sub(user, "sub-abc-123")
      assert linked.oidc_sub == "sub-abc-123"
      assert linked.id == user.id
    end

    test "refuses to link the same sub to two users" do
      alice = user_fixture(%{"username" => "alice"})
      bob = user_fixture(%{"username" => "bob"})

      {:ok, _} = Accounts.link_oidc_sub(alice, "sub-abc-123")

      assert {:error, changeset} = Accounts.link_oidc_sub(bob, "sub-abc-123")
      assert "has already been taken" in errors_on(changeset).oidc_sub
    end
  end

  describe "any_user?/0" do
    # No `refute` on an empty table here: this case is `async: true`, so
    # concurrently-running tests create users in the same database and a
    # global "table is empty" assertion is not stable.
    test "true once a user exists" do
      _user = user_fixture(%{"username" => "alice"})
      assert Accounts.any_user?()
    end
  end
end
