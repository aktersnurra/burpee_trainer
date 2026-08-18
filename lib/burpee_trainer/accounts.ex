defmodule BurpeeTrainer.Accounts do
  @moduledoc """
  OIDC-backed authentication context. All data elsewhere is scoped by
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
  Resolve an OIDC identity to a local user, linking or creating as needed.

  Order matters:

    1. A user already linked to this `sub` — the steady state after first login.
    2. A user with this username and no `sub` yet — adopted, so an existing
       account keeps its history instead of being shadowed by a new one.
    3. A user with this username already linked to a *different* `sub` —
       refused. Two identities claiming one account is a conflict to surface,
       never to resolve by guessing.
    4. Nobody with this username — created and linked.

  Runs in a transaction so a concurrent callback cannot create the same
  username twice; the unique indexes on `username` and `oidc_sub` are the
  backstop.
  """
  @spec resolve_oidc_identity(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :username_missing | :sub_conflict | Ecto.Changeset.t()}
  def resolve_oidc_identity(sub, username)

  def resolve_oidc_identity(sub, username)
      when is_binary(sub) and sub != "" and is_binary(username) and username != "" do
    Repo.transaction(fn ->
      case get_user_by_oidc_sub(sub) do
        %User{} = user ->
          user

        nil ->
          case get_user_by_username(username) do
            nil ->
              case create_user(%{"username" => username, "oidc_sub" => sub}) do
                {:ok, user} -> user
                {:error, changeset} -> Repo.rollback(changeset)
              end

            %User{oidc_sub: nil} = user ->
              case link_oidc_sub(user, sub) do
                {:ok, linked} -> linked
                {:error, changeset} -> Repo.rollback(changeset)
              end

            %User{} ->
              Repo.rollback(:sub_conflict)
          end
      end
    end)
  end

  def resolve_oidc_identity(_sub, _username), do: {:error, :username_missing}

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
