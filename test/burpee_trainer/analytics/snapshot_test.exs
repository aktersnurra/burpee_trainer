defmodule BurpeeTrainer.Analytics.SnapshotTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Analytics.{Schema, Snapshot}
  alias BurpeeTrainer.Workouts.WorkoutSession

  @now ~U[2026-10-20 12:00:00Z]

  test "projection excludes foreign, future and non-authoritative rows and stays immutable" do
    user = user_fixture()
    owned = insert_session(user, %{note_post: "SECRET", tags: "not-warmup"})
    insert_session(user_fixture(), %{burpee_count_actual: 999_999})
    insert_session(user, %{completed_at: DateTime.add(@now, 1)})

    {:ok, _started} =
      BurpeeTrainer.Workouts.start_plan(
        Scope.for_user(user),
        plan_fixture(user).id,
        Ecto.UUID.generate()
      )

    assert {:ok, snapshot} = Snapshot.build(Scope.for_user(user), now: @now)
    assert snapshot.schema_version == 1
    assert snapshot.as_of == @now
    assert [row] = snapshot.rows
    assert length(row) == length(Schema.columns())
    facts = Map.new(Enum.zip(Schema.columns(), row))
    assert facts["session_id"] == owned.id
    assert facts["credited_seconds"] == 600
    assert facts["pace_sec"] == 20.0
    assert facts["reps_per_20_min"] == 60
    refute "SECRET" in row
    Repo.update!(Ecto.Changeset.change(owned, tags: "warmup"))
    assert snapshot.rows == [row]
    assert {:ok, updated} = Snapshot.build(Scope.for_user(user), now: @now)
    assert Enum.at(hd(updated.rows), 10) == 0
  end

  test "DST local dates and missing actuals never borrow planned work" do
    user = %{user_fixture() | timezone: "America/Los_Angeles"}

    insert_session(user, %{
      completed_at: ~U[2026-03-08 07:59:59Z],
      burpee_count_actual: 0,
      duration_sec_actual: 0,
      burpee_count_planned: 100
    })

    insert_session(user, %{completed_at: ~U[2026-03-08 10:00:00Z], tags: "warmup"})
    assert {:ok, %{rows: [missing, warmup]}} = Snapshot.build(Scope.for_user(user), now: @now)
    assert Enum.at(missing, 2) == "2026-03-07"
    assert Enum.at(missing, 6) == 0
    assert Enum.at(missing, 7) == 100
    assert Enum.at(missing, 12) == nil
    assert Enum.at(missing, 13) == nil
    assert Enum.at(warmup, 2) == "2026-03-08"
    assert Enum.at(warmup, 10) == 0
    assert Enum.at(warmup, 11) == 1
  end

  test "unknown timezone refuses and candidate overflow is not biased truncation" do
    user = user_fixture()

    assert {:error, :invalid_timezone} =
             Snapshot.build(Scope.for_user(%{user | timezone: "Invalid/Zone"}), now: @now)

    row = %{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged,
      completed_at: @now,
      burpee_type: :six_count,
      burpee_count_actual: 30,
      duration_sec_actual: 600,
      inserted_at: @now,
      updated_at: @now
    }

    row
    |> List.duplicate(5_001)
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(WorkoutSession, &1))

    assert {:error, :snapshot_too_large} = Snapshot.build(Scope.for_user(user), now: @now)
  end

  test "integer representability refuses the whole snapshot without changing metrics" do
    user = user_fixture()
    max_integer = 9_223_372_036_854_775_807
    insert_session(user, %{burpee_count_actual: max_integer, duration_sec_actual: 2400})
    assert {:ok, %{rows: [row]}} = Snapshot.build(Scope.for_user(user), now: @now)
    assert Enum.at(row, 6) == max_integer
    assert Enum.at(row, 13) == round(max_integer / 2400 * 1200.0)

    insert_session(user, %{burpee_count_actual: max_integer, duration_sec_actual: 1})
    assert {:error, :invalid_snapshot} = Snapshot.build(Scope.for_user(user), now: @now)
  end

  test "malformed negative actuals remain NULL rather than becoming planned work" do
    user = user_fixture()

    insert_session(user, %{
      burpee_count_actual: -1,
      duration_sec_actual: -10,
      burpee_count_planned: 30,
      duration_sec_planned: 600
    })

    assert {:ok, %{rows: [row]}} = Snapshot.build(Scope.for_user(user), now: @now)
    assert Enum.at(row, 6) == nil
    assert Enum.at(row, 8) == nil
    assert Enum.at(row, 10) == 0
    assert Enum.at(row, 12) == nil
  end

  defp insert_session(user, attrs) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged,
      burpee_type: :six_count,
      completed_at: @now,
      burpee_count_actual: 30,
      duration_sec_actual: 600
    }
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  test "trusted timeout can tighten database waits but invalid or expired allowance refuses" do
    scope = scope_fixture()
    assert {:error, :invalid_timeout} = Snapshot.build(scope, timeout: 0)
    assert {:error, :invalid_timeout} = Snapshot.build(scope, timeout: -1)
    assert {:error, :invalid_timeout} = Snapshot.build(scope, timeout: :infinity)
    assert {:ok, %Snapshot{rows: []}} = Snapshot.build(scope, timeout: 1000)
  end
end
