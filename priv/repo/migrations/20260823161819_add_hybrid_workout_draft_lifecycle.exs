defmodule BurpeeTrainer.Repo.Migrations.AddHybridWorkoutDraftLifecycle do
  use Ecto.Migration

  @legacy_compile_policy_json_encoded ~s({"policy":"legacy_frozen","source_version":1,"version":1})

  @doc false
  def legacy_compile_policy_json, do: Jason.decode!(@legacy_compile_policy_json_encoded)

  @doc false
  def legacy_compile_policy_hash do
    @legacy_compile_policy_json_encoded
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def backfill_statements do
    [
      """
      UPDATE coach_workout_drafts
      SET revision_number = COALESCE(revision_number, 1),
          generation_attempt_count = COALESCE(generation_attempt_count, 1),
          compile_policy_json = CASE
            WHEN compile_policy_json IS NULL OR compile_policy_json = 'null'
              THEN '#{@legacy_compile_policy_json_encoded}'
            ELSE compile_policy_json
          END,
          compile_policy_hash = COALESCE(compile_policy_hash, '#{legacy_compile_policy_hash()}')
      WHERE compile_policy_json IS NULL OR compile_policy_json = 'null' OR compile_policy_hash IS NULL
      """
    ]
  end

  def up do
    alter table(:coach_workout_drafts) do
      add :parent_coach_workout_draft_id,
          references(:coach_workout_drafts, on_delete: :nilify_all)

      add :revision_number, :integer, null: false, default: 1
      add :generation_attempt_count, :integer, null: false, default: 1
      add :compile_policy_json, :map
      add :compile_policy_hash, :string
    end

    create index(:coach_workout_drafts, [:parent_coach_workout_draft_id, :revision_number])

    create unique_index(:coach_workout_drafts, [:user_id],
             where: "lifecycle_status = 'pending'",
             name: :coach_workout_drafts_one_pending_per_user_index
           )

    for statement <- backfill_statements() do
      execute(statement)
    end
  end

  def down do
    drop_if_exists index(:coach_workout_drafts, [:parent_coach_workout_draft_id, :revision_number])

    drop_if_exists unique_index(:coach_workout_drafts, [:user_id],
                     where: "lifecycle_status = 'pending'",
                     name: :coach_workout_drafts_one_pending_per_user_index
                   )

    alter table(:coach_workout_drafts) do
      remove :compile_policy_hash
      remove :compile_policy_json
      remove :generation_attempt_count
      remove :revision_number
      remove :parent_coach_workout_draft_id
    end
  end
end
