defmodule BurpeeTrainer.Repo.Migrations.GuardWorkoutApprovalKeys do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TRIGGER workout_plans_approval_key_immutable_trigger
    BEFORE UPDATE OF approval_key ON workout_plans
    FOR EACH ROW WHEN NEW.approval_key IS NOT OLD.approval_key
    BEGIN
      SELECT RAISE(ABORT, 'workout_plans_approval_key_immutable_check');
    END
    """)
  end

  def down, do: execute("DROP TRIGGER workout_plans_approval_key_immutable_trigger")
end
