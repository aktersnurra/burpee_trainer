defmodule BurpeeTrainer.Workouts.PoseCaptureTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk}

  test "capture evidence is bound to an owned immutable session" do
    {user, session} = started_session()

    assert {:ok, %PoseCaptureRun{} = run} = Workouts.start_pose_capture_run(user, session)
    assert run.user_id == user.id
    assert run.workout_session_id == session.id
    assert run.status == :active
  end

  test "appends validated chunks and rejects another user" do
    {owner, session} = started_session()
    intruder = user_fixture()
    {:ok, run} = Workouts.start_pose_capture_run(owner, session)
    attrs = chunk_attrs()

    assert {:ok, %PoseTraceChunk{} = chunk} =
             Workouts.append_pose_trace_chunk(owner, run, attrs)

    assert chunk.pose_capture_run_id == run.id
    assert {:error, :not_found} = Workouts.append_pose_trace_chunk(intruder, run, attrs)
  end

  test "rejects malformed and oversized chunk payloads" do
    {user, session} = started_session()
    {:ok, run} = Workouts.start_pose_capture_run(user, session)

    assert {:error, changeset} =
             Workouts.append_pose_trace_chunk(
               user,
               run,
               Map.put(chunk_attrs(), "sample_count", 2)
             )

    assert %{payload_json: ["sample count must match samples length"]} = errors_on(changeset)

    large_payload = Jason.encode!(%{"samples" => [%{"blob" => String.duplicate("x", 300_000)}]})

    assert {:error, oversized} =
             Workouts.append_pose_trace_chunk(
               user,
               run,
               Map.put(chunk_attrs(), "payload_json", large_payload)
             )

    assert %{payload_json: ["is too large"]} = errors_on(oversized)
  end

  test "completion requires the exact bound session to be completed" do
    {user, started} = started_session()
    {:ok, run} = Workouts.start_pose_capture_run(user, started)

    assert {:error, :not_found} = Workouts.complete_pose_capture_run(user, run, started)

    unchanged = Repo.get!(PoseCaptureRun, run.id)
    assert unchanged.status == :active
    assert unchanged.completed_at == nil
    assert unchanged.workout_session_id == started.id
  end

  test "completes and aborts session-owned capture runs" do
    {user, started} = started_session()
    {:ok, completed_run} = Workouts.start_pose_capture_run(user, started)

    {:ok, completed_session} =
      Workouts.complete_session(
        user,
        started.id,
        %{"burpee_count_actual" => 20, "duration_sec_actual" => 600},
        :timed
      )

    assert {:ok, completed_run} =
             Workouts.complete_pose_capture_run(user, completed_run, completed_session)

    assert completed_run.status == :completed
    assert completed_run.workout_session_id == completed_session.id

    {other_user, other_session} = started_session()
    {:ok, aborted_run} = Workouts.start_pose_capture_run(other_user, other_session)
    {:ok, chunk} = Workouts.append_pose_trace_chunk(other_user, aborted_run, chunk_attrs())
    assert :ok = Workouts.abort_pose_capture_run(other_user, aborted_run, "user_discarded")
    refute Repo.get(PoseCaptureRun, aborted_run.id)
    refute Repo.get(PoseTraceChunk, chunk.id)
  end

  defp started_session do
    user = user_fixture()
    plan = plan_fixture(user)
    {:ok, session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    {user, session}
  end

  defp chunk_attrs do
    %{
      "segment" => "main",
      "chunk_index" => 0,
      "started_at_ms" => 0,
      "ended_at_ms" => 3_000,
      "sample_count" => 1,
      "payload_json" => Jason.encode!(%{"samples" => [%{"tMs" => 0}]})
    }
  end
end
