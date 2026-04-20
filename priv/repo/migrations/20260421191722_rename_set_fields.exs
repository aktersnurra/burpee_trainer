defmodule BurpeeTrainer.Repo.Migrations.RenameSetFields do
  use Ecto.Migration

  def change do
    rename table(:sets), :sec_per_burpee, to: :sec_per_rep
    rename table(:sets), :rest_sec_after_set, to: :end_of_set_rest

    alter table(:sets) do
      add :sec_per_burpee, :float, null: false, default: 3.0
    end
  end
end
