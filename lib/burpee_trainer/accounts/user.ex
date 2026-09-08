defmodule BurpeeTrainer.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :oidc_sub, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a user from a username alone. Users are
  provisioned in Pocket ID; this exists for seeding and tests.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :oidc_sub])
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 32)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_.-]+$/,
      message: "may only contain letters, numbers, and _ . -"
    )
    |> unique_constraint(:username)
    |> unique_constraint(:oidc_sub)
  end

  @doc """
  Changeset that links an OIDC subject identifier to an existing user.
  """
  def oidc_link_changeset(user, oidc_sub) when is_binary(oidc_sub) do
    user
    |> cast(%{oidc_sub: oidc_sub}, [:oidc_sub])
    |> validate_required([:oidc_sub])
    |> unique_constraint(:oidc_sub)
  end
end
