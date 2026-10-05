defmodule BurpeeTrainer.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Accounts.{Scope, User}

  test "for_user wraps a user and nil stays nil" do
    user = %User{id: 7}

    assert %Scope{user: ^user} = Scope.for_user(user)
    assert Scope.for_user(nil) == nil
  end
end
