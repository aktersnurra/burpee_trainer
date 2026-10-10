defmodule BurpeeTrainer.Evals.OwnerTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Coach.Ledger
  alias BurpeeTrainer.Evals.Owner

  test "dedicated owned user and all its calls cleaned even on exception, no foreign deletion" do
    foreign = user_fixture()

    assert_raise RuntimeError, "boom", fn ->
      Owner.with_owner(fn scope ->
        send(self(), {:eval_identity, scope.user.id, scope.user.username})
        assert scope.user.username =~ "eval-"

        assert {:ok, _call} =
                 Ledger.reserve(scope, %{
                   purpose: "layout",
                   run_id: Ecto.UUID.generate(),
                   model: "m"
                 })

        raise "boom"
      end)
    end

    assert_receive {:eval_identity, id, name}
    assert Accounts.get_user(id) == nil
    assert Accounts.get_user_by_username(name) == nil
    assert Accounts.get_user(foreign.id).id == foreign.id
    assert Repo.aggregate(BurpeeTrainer.Coach.LlmCall, :count) == 0
  end
end
