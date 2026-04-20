defmodule BurpeeTrainer.AccountsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainer.Accounts.User

  import BurpeeTrainer.Fixtures

  describe "register_user/1" do
    test "creates a user and hashes the password" do
      assert {:ok, %User{} = user} =
               Accounts.register_user(%{
                 "username" => "alice",
                 "password" => "correct-horse-battery-staple"
               })

      assert user.username == "alice"
      assert is_binary(user.password_hash)
      assert user.password == nil
      refute user.password_hash == "correct-horse-battery-staple"
    end

    test "rejects a username that is too short" do
      assert {:error, changeset} =
               Accounts.register_user(%{"username" => "ab", "password" => "longenoughpw"})

      assert %{username: [_ | _]} = errors_on(changeset)
    end

    test "rejects a username with disallowed characters" do
      assert {:error, changeset} =
               Accounts.register_user(%{"username" => "bad name!", "password" => "longenoughpw"})

      assert %{username: [_ | _]} = errors_on(changeset)
    end

    test "rejects a password that is too short" do
      assert {:error, changeset} =
               Accounts.register_user(%{"username" => "alice", "password" => "short"})

      assert %{password: [_ | _]} = errors_on(changeset)
    end

    test "rejects a duplicate username" do
      _ = user_fixture(%{"username" => "taken"})

      assert {:error, changeset} =
               Accounts.register_user(%{"username" => "taken", "password" => "longenoughpw"})

      assert %{username: [_ | _]} = errors_on(changeset)
    end
  end

  describe "authenticate_user/2" do
    test "returns the user on correct credentials" do
      user = user_fixture(%{"username" => "alice", "password" => "longenoughpw"})

      assert {:ok, authed} = Accounts.authenticate_user("alice", "longenoughpw")
      assert authed.id == user.id
    end

    test "returns :invalid_credentials on wrong password" do
      _ = user_fixture(%{"username" => "alice", "password" => "longenoughpw"})

      assert {:error, :invalid_credentials} = Accounts.authenticate_user("alice", "wrong-pass")
    end

    test "returns :invalid_credentials when the user does not exist" do
      assert {:error, :invalid_credentials} = Accounts.authenticate_user("ghost", "whatever123")
    end
  end

  describe "lookup helpers" do
    test "get_user!/1 raises when missing, returns struct when present" do
      user = user_fixture()
      assert Accounts.get_user!(user.id).id == user.id

      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(user.id + 99_999) end
    end

    test "get_user_by_username/1 returns nil when missing" do
      assert Accounts.get_user_by_username("nope") == nil
    end

    test "any_user?/0 reflects whether a user exists" do
      refute Accounts.any_user?()
      _ = user_fixture()
      assert Accounts.any_user?()
    end
  end
end
