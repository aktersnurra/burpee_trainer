defmodule BurpeeTrainer.AccountsTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Accounts.User

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

  describe "update_timezone/2 reconciliation wake" do
    test "persists before waking and unchanged provisioned timezones stay write-free" do
      user = user_fixture()
      now = ~U[2026-08-25 02:00:00Z]
      parent = self()

      wake = fn user_id, reason ->
        persisted = Repo.get!(User, user_id)
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

      assert Repo.get!(User, user.id).timezone == "Europe/Stockholm"
      assert updated.timezone == "Europe/Stockholm"
    end
  end

  defp insert_users(count) do
    now = DateTime.utc_now(:second)

    rows =
      for number <- 1..count do
        %{
          username: "paged_user_#{number}",
          timezone: "Etc/UTC",
          timezone_provisioned: true,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(User, rows)
  end
end
