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

  describe "update_timezone/2" do
    test "provisioning and changing timezone never enqueue planning or replace the first-use starter" do
      user = user_fixture()
      assert {:ok, provisioned} = Accounts.update_timezone(user, "America/Los_Angeles")
      assert provisioned.timezone_provisioned
      assert {:ok, updated} = Accounts.update_timezone(provisioned, "Europe/Stockholm")
      assert updated.timezone == "Europe/Stockholm"
      assert Repo.aggregate(Oban.Job, :count) == 0
      scope = BurpeeTrainer.Accounts.Scope.for_user(updated)

      assert {:ok, slot} =
               BurpeeTrainer.Coach.Policy.required_slot(scope, DateTime.utc_now(:second))

      assert slot.home_state == :workout_needed
      assert {:ok, facts} = BurpeeTrainer.Home.facts(scope, DateTime.utc_now(:second))

      assert {:start, %{plan: %{name: "Starter Six-Count"}}} = BurpeeTrainer.Home.state(facts)
      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "an unchanged provisioned timezone is write-free" do
      user = user_fixture()
      assert {:ok, updated} = Accounts.update_timezone(user, "America/Los_Angeles")
      parent = self()
      handler = "unchanged-timezone-#{Ecto.UUID.generate()}"

      :ok =
        :telemetry.attach(
          handler,
          [:burpee_trainer, :repo, :query],
          # Telemetry handlers are global and run in the querying process: count only ours.
          fn _, _, metadata, _ ->
            if self() == parent, do: send(parent, {:timezone_query, metadata.query})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert {:ok, same} = Accounts.update_timezone(updated, "America/Los_Angeles")
      assert same == updated
      refute_receive {:timezone_query, _}
    end

    test "invalid timezone and failed writes preserve persisted data" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.update_timezone(user, "Mars/Olympus_Mons")
      assert Repo.reload!(user) == user
      stale_user = %{user | id: user.id + 99_999}

      assert_raise Ecto.StaleEntryError, fn ->
        Accounts.update_timezone(stale_user, "Europe/Stockholm")
      end

      assert Repo.aggregate(Oban.Job, :count) == 0
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
