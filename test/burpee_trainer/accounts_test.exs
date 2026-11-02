defmodule BurpeeTrainer.AccountsTest do
  use BurpeeTrainer.DataCase

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Accounts, Repo}

  describe "get_user_by_oidc_sub/1" do
    test "matches only a linked sub, never an unknown, nil, or empty one" do
      user = user_fixture(%{"username" => "alice"})
      _unlinked = user_fixture(%{"username" => "bob"})
      {:ok, user} = Accounts.link_oidc_sub(user, "sub-abc-123")

      assert %{id: id} = Accounts.get_user_by_oidc_sub("sub-abc-123")
      assert id == user.id

      for sub <- ["sub-nope", nil, ""] do
        assert Accounts.get_user_by_oidc_sub(sub) == nil
      end
    end
  end

  describe "link_oidc_sub/2" do
    test "refuses to link the same sub to two users" do
      alice = user_fixture(%{"username" => "alice"})
      bob = user_fixture(%{"username" => "bob"})

      {:ok, _} = Accounts.link_oidc_sub(alice, "sub-abc-123")

      assert {:error, changeset} = Accounts.link_oidc_sub(bob, "sub-abc-123")
      assert "has already been taken" in errors_on(changeset).oidc_sub
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
end
