defmodule BurpeeTrainer.Accounts do
  @moduledoc """
  Single-user authentication context. All data elsewhere is scoped by
  `user_id`; the app is multi-user-capable even though only one user
  actually exists.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.{CoachReconciler, Repo}

  @users_page_limit 100

  @doc """
  List the next fixed-size page of users ordered by id.
  """
  @spec list_users_page(non_neg_integer() | nil) :: [User.t()]
  def list_users_page(after_user_id \\ nil)

  def list_users_page(nil) do
    Repo.all(from(user in User, order_by: [asc: user.id], limit: @users_page_limit))
  end

  def list_users_page(after_user_id) when is_integer(after_user_id) and after_user_id >= 0 do
    Repo.all(
      from(user in User,
        where: user.id > ^after_user_id,
        order_by: [asc: user.id],
        limit: @users_page_limit
      )
    )
  end

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
    Repo.one(from(u in User, where: u.username == ^username))
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
  Persist a valid IANA timezone, avoiding a database write and reconciliation
  wake when an already-provisioned timezone is unchanged.
  """
  @spec update_timezone(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_timezone(%User{} = user, timezone) do
    update_timezone_at(user, timezone, DateTime.utc_now(:second))
  end

  @doc false
  @spec update_timezone_at(User.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_timezone_at(%User{} = user, timezone, %DateTime{} = _now, opts \\ []) do
    changeset = User.timezone_changeset(user, %{timezone: timezone})

    if changeset.valid? and user.timezone == timezone and user.timezone_provisioned do
      {:ok, user}
    else
      wake = Keyword.get(opts, :wake, &CoachReconciler.wake/2)

      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, updated_user} -> updated_user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, updated_user} ->
          best_effort_wake(wake, updated_user.id, :timezone_changed)
          {:ok, updated_user}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp best_effort_wake(wake, user_id, reason) do
    try do
      wake.(user_id, reason)
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
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
