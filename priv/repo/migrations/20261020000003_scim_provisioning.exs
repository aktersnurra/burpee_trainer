defmodule BurpeeTrainer.Repo.Migrations.ScimProvisioning do
  @moduledoc """
  Pocket ID provisions users and groups over SCIM. `users.access` is whether the user may
  use the app (`active`, `disabled` when blocked in Pocket ID, `removed` when they lost
  access to the client; their data is kept). `scim_synced_at` is the last SCIM write,
  which Pocket ID compares with its own change time. `scim_groups` keeps the groups it
  sends, so membership of the coach group decides `users.coach`.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :access, :string, null: false, default: "active"
      add :scim_synced_at, :utc_datetime
    end

    create table(:scim_groups) do
      add :external_id, :string, null: false
      add :display_name, :string, null: false
      add :member_ids, :text, null: false, default: "[]"
      add :scim_synced_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scim_groups, [:external_id])
  end
end
