defmodule BurpeeTrainer.Repo.Migrations.AddOidcSubToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :oidc_sub, :string
      remove :password_hash, :string, null: false
    end

    create unique_index(:users, [:oidc_sub])
  end
end
