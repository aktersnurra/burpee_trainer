defmodule BurpeeTrainer.Workouts.PoseCorpusTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.PoseCorpus

  @tag :tmp_dir
  test "exports a session's main segment in chunk order with its counts and program", %{
    tmp_dir: tmp_dir
  } do
    user = user_fixture()
    scope = Scope.for_user(user)
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())

    {:ok, session} =
      Workouts.complete_session(
        scope,
        started.id,
        %{"burpee_count_actual" => 30, "duration_sec_actual" => 120},
        :timed
      )

    chunks = [
      chunk("main", 2, [%{"tMs" => 2_000, "usable" => false}], [1_900]),
      chunk("warmup", 0, [%{"tMs" => 0}], []),
      chunk("main", 1, [%{"tMs" => 1_000}, %{"tMs" => 1_100, "reset" => true}], [900])
    ]

    assert {:ok, %{complete: true}} =
             Workouts.ingest_pose_trace_batch(
               scope,
               session.id,
               session.client_session_id,
               chunks,
               true
             )

    assert [path] = PoseCorpus.export(tmp_dir)
    assert Path.basename(path) == "session-#{session.id}.json.gz"

    trace = path |> File.read!() |> :zlib.gunzip() |> Jason.decode!()

    assert trace["samples"] == [
             %{"tMs" => 1_000},
             %{"tMs" => 1_100, "reset" => true},
             %{"tMs" => 2_000, "usable" => false}
           ]

    assert trace["camera_reps_ms"] == [900, 1_900]
    assert trace["version"] == 2
    assert trace["reps"] == 30
    assert trace["reps_planned"] == session.burpee_count_planned
    assert trace["program"] == Jason.decode!(Jason.encode!(session.program_snapshot))
  end

  defp chunk(segment, index, samples, reps) do
    %{
      "segment" => segment,
      "chunk_index" => index,
      "started_at_ms" => index * 1_000,
      "ended_at_ms" => index * 1_000 + 500,
      "sample_count" => length(samples),
      "payload" => %{"version" => 2, "samples" => samples, "reps" => reps}
    }
  end
end
