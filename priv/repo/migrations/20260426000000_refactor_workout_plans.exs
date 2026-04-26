defmodule BurpeeTrainer.Repo.Migrations.RefactorWorkoutPlans do
  use Ecto.Migration

  def change do
    alter table(:workout_plans) do
      remove :warmup_enabled
      remove :warmup_reps
      remove :warmup_rounds
      remove :rest_sec_warmup_between
      remove :rest_sec_warmup_before_main
      remove :shave_off_sec
      remove :shave_off_block_count
      add :target_duration_min, :integer
      add :burpee_count_target, :integer
      add :sec_per_burpee, :float
      add :pacing_style, :string
      add :additional_rests, :text
    end
  end
end
