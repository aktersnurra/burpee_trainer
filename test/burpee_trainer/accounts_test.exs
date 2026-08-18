defmodule BurpeeTrainer.AccountsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.{Accounts, Repo}
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

  describe "list_users_page/1" do
    test "returns users in fixed, id-ordered pages" do
      insert_users(101)

      first_page = Accounts.list_users_page(nil)
      second_page = Accounts.list_users_page(List.last(first_page).id)
      final_page = Accounts.list_users_page(List.last(second_page).id)

      assert length(first_page) == 100
      assert length(second_page) == 1
      assert final_page == []

      ids = Enum.map(first_page ++ second_page, & &1.id)
      assert ids == Enum.sort(ids)
      assert length(Enum.uniq(ids)) == 101
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

  describe "update_timezone/2 reconciliation wake" do
    test "persists before waking and unchanged provisioned timezones stay write-free" do
      user = user_fixture()
      now = ~U[2026-08-25 02:00:00Z]
      parent = self()

      wake = fn user_id, reason ->
        persisted = Accounts.get_user!(user_id)
        send(parent, {:timezone_wake, user_id, reason, persisted.timezone})
        :ok
      end

      assert {:ok, updated} =
               Accounts.update_timezone_at(user, "America/Los_Angeles", now, wake: wake)

      assert updated.timezone == "America/Los_Angeles"
      assert updated.timezone_provisioned

      assert_receive {:timezone_wake, user_id, :timezone_changed, "America/Los_Angeles"}
      assert user_id == user.id

      previous_updated_at = updated.updated_at

      assert {:ok, same} =
               Accounts.update_timezone_at(updated, "America/Los_Angeles", now, wake: wake)

      assert same.id == updated.id
      assert same.updated_at == previous_updated_at
      refute_receive {:timezone_wake, _, _, _}
    end

    test "invalid timezone and failed writes send no wake" do
      user = user_fixture()
      parent = self()
      wake = fn user_id, reason -> send(parent, {:timezone_wake, user_id, reason}) end

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_timezone_at(user, "Mars/Olympus_Mons", ~U[2026-08-25 10:00:00Z],
                 wake: wake
               )

      refute_receive {:timezone_wake, _, _}

      stale_user = %{user | id: user.id + 99_999}

      assert_raise Ecto.StaleEntryError, fn ->
        Accounts.update_timezone_at(stale_user, "Europe/Stockholm", ~U[2026-08-25 10:00:00Z],
          wake: wake
        )
      end

      refute_receive {:timezone_wake, _, _}
    end

    test "wake failure does not undo the committed timezone" do
      user = user_fixture()
      wake = fn _user_id, _reason -> raise "wake unavailable" end

      assert {:ok, updated} =
               Accounts.update_timezone_at(user, "Europe/Stockholm", ~U[2026-08-25 10:00:00Z],
                 wake: wake
               )

      assert Accounts.get_user!(user.id).timezone == "Europe/Stockholm"
      assert updated.timezone == "Europe/Stockholm"
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

  defp insert_users(count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for number <- 1..count do
        %{
          username: "paged_user_#{number}",
          password_hash: "not-used",
          timezone: "Etc/UTC",
          timezone_provisioned: true,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(User, rows)
  end
end
