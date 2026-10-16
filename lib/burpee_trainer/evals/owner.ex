defmodule BurpeeTrainer.Evals.Owner do
  @moduledoc "Creates and tears down only the dedicated identity of a single owner eval run."
  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Accounts.{Scope, User}
  import Ecto.Query

  def with_owner(callback) when is_function(callback, 1) do
    username = "eval-" <> Base.encode32(Ecto.UUID.bingenerate(), case: :lower, padding: false)
    {:ok, user} = Accounts.create_user(%{"username" => username})
    scope = Scope.for_user(user)

    try do
      callback.(scope)
    after
      cleanup(scope, username)
    end
  end

  defp cleanup(%Scope{user: %{id: id}}, username) do
    Repo.immediate_transaction(fn ->
      case Repo.one(from u in User, where: u.id == ^id and u.username == ^username) do
        %User{} = user -> Repo.delete!(user)
        nil -> raise "Eval identity changed; refusing broad cleanup"
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Eval cleanup failed: #{inspect(reason)}"
    end
  end
end
