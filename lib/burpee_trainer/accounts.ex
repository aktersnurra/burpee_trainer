defmodule BurpeeTrainer.Accounts do
  @moduledoc """
  Single-user authentication context. All data elsewhere is scoped by
  `user_id`; the app is multi-user-capable even though only one user
  actually exists.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Repo

  @doc """
  Fetch a user by id, raising if not found.
  """
  @spec get_user!(integer) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Fetch a user by id, returning nil if not found.
  """
  @spec get_user(integer) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Fetch a user by username, returning nil if not found.
  """
  @spec get_user_by_username(String.t()) :: User.t() | nil
  def get_user_by_username(username) when is_binary(username) do
    Repo.one(from u in User, where: u.username == ^username)
  end

  @doc """
  Authenticate a user by username + plaintext password. Always spends
  bcrypt time even when the user doesn't exist, to prevent enumeration
  via timing.
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(username, password) when is_binary(username) and is_binary(password) do
    user = get_user_by_username(username)

    cond do
      user && Bcrypt.verify_pass(password, user.password_hash) ->
        {:ok, user}

      user ->
        {:error, :invalid_credentials}

      true ->
        # No user with that username — spend the same time hashing so
        # response time doesn't leak whether the user exists.
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Create a user. Used by the `mix burpee_trainer.create_user` task.
  """
  @spec register_user(map) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Return a blank registration changeset, useful for login/registration
  forms.
  """
  @spec change_user_registration(User.t(), map) :: Ecto.Changeset.t()
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  True when any user exists. Used by the mix task to avoid double-seeding.
  """
  @spec any_user?() :: boolean
  def any_user? do
    Repo.exists?(User)
  end
end
