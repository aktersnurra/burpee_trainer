defmodule BurpeeTrainer.Repo.Migrations.UsersCoachEnabled do
  @moduledoc """
  Whether the app's own coach (its model) runs for the user, set from a Pocket ID claim at
  every sign-in. Existing users keep the coach until their next sign-in.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :coach_enabled, :boolean, null: false, default: true
    end
  end
end
