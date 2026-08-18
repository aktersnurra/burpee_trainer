defmodule BurpeeTrainer.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :timezone, :string, default: "Etc/UTC"
    field :timezone_provisioned, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for persisting a browser-provided IANA timezone.
  """
  def timezone_changeset(user, attrs) do
    user
    |> cast(attrs, [:timezone])
    |> validate_required([:timezone])
    |> validate_change(:timezone, fn :timezone, timezone ->
      if Tzdata.zone_exists?(timezone), do: [], else: [timezone: "is not a valid IANA timezone"]
    end)
    |> put_change(:timezone_provisioned, true)
  end

  @doc """
  Changeset for registering a user from username + plaintext password.
  The plaintext is hashed into `password_hash` and then stripped from
  the changeset so it never lands in the struct.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> validate_length(:username, min: 3, max: 32)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_.-]+$/,
      message: "may only contain letters, numbers, and _ . -"
    )
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username)
    |> put_password_hash()
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
