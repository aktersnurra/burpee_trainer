defmodule BurpeeTrainer.Repo.Migrations.UniquePublishedBuiltInNames do
  use Ecto.Migration

  # Home looks built-ins up by name ("Built-in Steady 10", the starters), so each name
  # names at most one published built-in. Archived generations keep their names.
  def change do
    create unique_index(:workout_plans, [:name],
             where: "user_id IS NULL AND origin = 'built_in' AND state = 'published'",
             name: :workout_plans_published_built_in_name_index
           )
  end
end
