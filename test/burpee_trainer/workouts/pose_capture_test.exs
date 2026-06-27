defmodule BurpeeTrainer.Workouts.PoseCaptureTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk}

  describe "pose capture runs" do
    test "starts a capture run scoped to a user and plan" do
      user = user_fixture()
      plan = plan_fixture(user)

      assert {:ok, %PoseCaptureRun{} = run} = Workouts.start_pose_capture_run(user, plan)

      assert run.user_id == user.id
      assert run.plan_id == plan.id
      assert run.workout_session_id == nil
      assert run.status == :active
      assert run.started_at
    end

    test "appends warmup and main chunks to a user's run" do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, run} = Workouts.start_pose_capture_run(user, plan)

      attrs = %{
        "segment" => "warmup",
        "chunk_index" => 0,
        "started_at_ms" => 0,
        "ended_at_ms" => 3_000,
        "sample_count" => 2,
        "payload_json" => Jason.encode!(%{"samples" => [%{"tMs" => 0}, %{"tMs" => 100}]})
      }

      assert {:ok, %PoseTraceChunk{} = chunk} =
               Workouts.append_pose_trace_chunk(user, run, attrs)

      assert chunk.pose_capture_run_id == run.id
      assert chunk.segment == :warmup
      assert chunk.chunk_index == 0
      assert chunk.sample_count == 2

      assert {:ok, %PoseTraceChunk{} = main_chunk} =
               Workouts.append_pose_trace_chunk(user, run, %{
                 attrs
                 | "segment" => "main",
                   "chunk_index" => 1
               })

      assert main_chunk.segment == :main
      assert main_chunk.chunk_index == 1
    end

    test "rejects chunks whose sample count does not match payload samples" do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, run} = Workouts.start_pose_capture_run(user, plan)

      assert {:error, changeset} =
               Workouts.append_pose_trace_chunk(user, run, %{
                 "segment" => "main",
                 "chunk_index" => 0,
                 "started_at_ms" => 0,
                 "ended_at_ms" => 3_000,
                 "sample_count" => 2,
                 "payload_json" => Jason.encode!(%{"samples" => [%{"tMs" => 0}]})
               })

      assert %{payload_json: ["sample count must match samples length"]} = errors_on(changeset)
    end

    test "rejects oversized pose chunk payloads" do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, run} = Workouts.start_pose_capture_run(user, plan)
      large_payload = Jason.encode!(%{"samples" => [%{"blob" => String.duplicate("x", 300_000)}]})

      assert {:error, changeset} =
               Workouts.append_pose_trace_chunk(user, run, %{
                 "segment" => "main",
                 "chunk_index" => 0,
                 "started_at_ms" => 0,
                 "ended_at_ms" => 3_000,
                 "sample_count" => 1,
                 "payload_json" => large_payload
               })

      assert %{payload_json: ["is too large"]} = errors_on(changeset)
    end

    test "rejects appending chunks to another user's run" do
      owner = user_fixture()
      intruder = user_fixture()
      plan = plan_fixture(owner)
      {:ok, run} = Workouts.start_pose_capture_run(owner, plan)

      assert {:error, :not_found} =
               Workouts.append_pose_trace_chunk(intruder, run, %{
                 "segment" => "main",
                 "chunk_index" => 0,
                 "started_at_ms" => 0,
                 "ended_at_ms" => 3_000,
                 "sample_count" => 1,
                 "payload_json" => Jason.encode!(%{"samples" => [%{"tMs" => 0}]})
               })
    end

    test "completes a capture run by linking it to a workout session" do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, run} = Workouts.start_pose_capture_run(user, plan)
      session = session_from_plan_fixture(user, plan)

      assert {:ok, %PoseCaptureRun{} = completed} =
               Workouts.complete_pose_capture_run(user, run, session)

      assert completed.status == :completed
      assert completed.workout_session_id == session.id
      assert completed.completed_at
    end

    test "aborts a capture run by deleting the run and chunks" do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, run} = Workouts.start_pose_capture_run(user, plan)

      {:ok, chunk} =
        Workouts.append_pose_trace_chunk(user, run, %{
          "segment" => "main",
          "chunk_index" => 0,
          "started_at_ms" => 0,
          "ended_at_ms" => 3_000,
          "sample_count" => 1,
          "payload_json" => Jason.encode!(%{"samples" => [%{"tMs" => 0}]})
        })

      assert :ok = Workouts.abort_pose_capture_run(user, run, "user_discarded")

      refute Repo.get(PoseCaptureRun, run.id)
      refute Repo.get(PoseTraceChunk, chunk.id)
    end
  end
end
