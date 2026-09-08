defmodule BurpeeTrainer.Accounts do
  @moduledoc """
  OIDC-backed authentication context. All data elsewhere is scoped by
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
  Fetch the user linked to an OIDC subject identifier. Returns nil when
  the sub is blank or unknown. Never creates a user.
  """
  @spec get_user_by_oidc_sub(String.t() | nil) :: User.t() | nil
  def get_user_by_oidc_sub(sub) when is_binary(sub) and sub != "" do
    Repo.one(from u in User, where: u.oidc_sub == ^sub)
  end

  def get_user_by_oidc_sub(_sub), do: nil

  @doc """
  Link an OIDC subject identifier to an existing user. Used by the
  `mix burpee_trainer.link_oidc` task, never during a login request.
  """
  @spec link_oidc_sub(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def link_oidc_sub(%User{} = user, sub) when is_binary(sub) do
    user
    |> User.oidc_link_changeset(sub)
    |> Repo.update()
  end

  @doc """
  Create a user. Users are normally provisioned in Pocket ID; this is for
  seeding and tests.
  """
  @spec create_user(map) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  True when any user exists. Used by the mix task to avoid double-seeding.
  """
  @spec any_user?() :: boolean
  def any_user? do
    Repo.exists?(User)
  end
end
