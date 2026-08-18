defmodule BurpeeTrainer.Repo.Migrations.BackfillCoachAcceptedProvenance do
  use Ecto.Migration

  @recommendation_backfill """
  UPDATE coach_recommendations
  SET validation_status = 'accepted',
      execution_program_id = (
        SELECT plans.current_execution_program_id
        FROM workout_plans AS plans
        JOIN execution_programs AS programs
          ON programs.id = plans.current_execution_program_id
        WHERE plans.id = coach_recommendations.workout_plan_id
      ),
      execution_program_hash = (
        SELECT programs.content_hash
        FROM workout_plans AS plans
        JOIN execution_programs AS programs
          ON programs.id = plans.current_execution_program_id
        WHERE plans.id = coach_recommendations.workout_plan_id
      )
  WHERE validation_status IS NULL
    AND execution_program_id IS NULL
    AND execution_program_hash IS NULL
    AND EXISTS (
      SELECT 1
      FROM workout_plans AS plans
      JOIN execution_programs AS programs
        ON programs.id = plans.current_execution_program_id
      WHERE plans.id = coach_recommendations.workout_plan_id
    )
  """

  @draft_backfill """
  UPDATE coach_workout_drafts
  SET validation_status = 'accepted',
      execution_program_id = (
        SELECT plans.current_execution_program_id
        FROM workout_plans AS plans
        JOIN execution_programs AS programs
          ON programs.id = plans.current_execution_program_id
        WHERE plans.id = coach_workout_drafts.workout_plan_id
      ),
      execution_program_hash = (
        SELECT programs.content_hash
        FROM workout_plans AS plans
        JOIN execution_programs AS programs
          ON programs.id = plans.current_execution_program_id
        WHERE plans.id = coach_workout_drafts.workout_plan_id
      )
  WHERE validation_status IS NULL
    AND execution_program_id IS NULL
    AND execution_program_hash IS NULL
    AND EXISTS (
      SELECT 1
      FROM workout_plans AS plans
      JOIN execution_programs AS programs
        ON programs.id = plans.current_execution_program_id
      WHERE plans.id = coach_workout_drafts.workout_plan_id
    )
  """

  @doc false
  def backfill_statements, do: [@recommendation_backfill, @draft_backfill]

  def up do
    Enum.each(backfill_statements(), &execute/1)
  end

  def down, do: :ok
end
