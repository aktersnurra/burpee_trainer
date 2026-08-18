defmodule BurpeeTrainer.TestSupport.AtomicMigrationProof do
  use Ecto.Migration

  @disable_ddl_transaction true
  @version 90_000_000_000_001

  def version, do: @version

  def up do
    repo().checkout(
      fn ->
        try do
          repo().query!("PRAGMA foreign_keys = OFF")
          assert_foreign_keys!(0)

          case terminal_state() do
            :source ->
              {:ok, :ok} =
                repo().transaction(
                  fn ->
                    rebuild()
                    :ok
                  end,
                  mode: :immediate,
                  timeout: :infinity
                )

              if action() == :commit_gap do
                raise "atomic proof commit/version gap"
              end

            :target ->
              validate_target!()
          end
        after
          repo().query!("PRAGMA foreign_keys = ON")
          assert_foreign_keys!(1)
        end
      end,
      timeout: :infinity
    )
  end

  def down do
    raise "proof migration is irreversible"
  end

  defp rebuild do
    execute(
      "CREATE TABLE atomic_target (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
    )

    execute("INSERT INTO atomic_target (id, value) SELECT id, value FROM atomic_legacy_parents")
    execute("CREATE TABLE atomic_helper (value TEXT NOT NULL)")
    execute("INSERT INTO atomic_helper (value) VALUES ('transient')")
    execute("DROP TRIGGER atomic_legacy_insert_trigger")
    execute("DROP TABLE atomic_legacy_children")
    execute("DROP TABLE atomic_legacy_parents")
    flush()

    repo().query!("UPDATE sqlite_sequence SET seq = 900 WHERE name = 'atomic_target'")

    case action() do
      :exception ->
        raise "atomic proof exception"

      :foreign_key_violation ->
        repo().query!(
          "CREATE TABLE atomic_violation (parent_id INTEGER REFERENCES atomic_target(id))"
        )

        repo().query!("INSERT INTO atomic_violation (parent_id) VALUES (999)")
        violations = repo().query!("PRAGMA foreign_key_check").rows
        send(proof_parent(), {:atomic_proof_foreign_key_violations, violations})
        raise "atomic proof foreign key violation"

      :owner_exit ->
        send(proof_parent(), {:atomic_proof_inside_transaction, self()})

        receive do
          :finish_atomic_proof -> :ok
        end

      action when action in [:success, :commit_gap] ->
        :ok
    end

    execute("DROP TABLE atomic_helper")
    flush()
    assert_no_foreign_key_violations!()
  end

  defp action do
    Application.fetch_env!(:burpee_trainer, :atomic_migration_proof_action)
  end

  defp terminal_state do
    source? = table_exists?("atomic_legacy_parents") and table_exists?("atomic_legacy_children")
    target? = table_exists?("atomic_target")

    case {source?, target?} do
      {true, false} -> :source
      {false, true} -> :target
      other -> raise "atomic proof unsupported terminal state: #{inspect(other)}"
    end
  end

  defp validate_target! do
    unless repo().query!("SELECT id, value FROM atomic_target ORDER BY id").rows == [
             [1, "legacy"]
           ] and
             not table_exists?("atomic_helper") do
      raise "atomic proof target validation failed"
    end
  end

  defp table_exists?(table) do
    repo().query!("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table]).rows !=
      []
  end

  defp proof_parent do
    Application.fetch_env!(:burpee_trainer, :atomic_migration_proof_parent)
  end

  defp assert_foreign_keys!(0) do
    if action() == :fk_verification_failure do
      raise "atomic proof foreign key verification failure"
    end

    assert_foreign_keys_value!(0)
  end

  defp assert_foreign_keys!(expected), do: assert_foreign_keys_value!(expected)

  defp assert_foreign_keys_value!(expected) do
    case repo().query!("PRAGMA foreign_keys").rows do
      [[^expected]] -> :ok
      rows -> raise "expected PRAGMA foreign_keys=#{expected}, got: #{inspect(rows)}"
    end
  end

  defp assert_no_foreign_key_violations! do
    case repo().query!("PRAGMA foreign_key_check").rows do
      [] -> :ok
      rows -> raise "atomic proof foreign key violations: #{inspect(rows)}"
    end
  end
end
