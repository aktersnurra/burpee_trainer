defmodule BurpeeTrainerWeb.PoseTraceUploadControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk}

  test "requires an authenticated user", %{conn: conn} do
    conn = post(conn, ~p"/api/session-pose-traces", %{"client_session_id" => "missing"})

    assert redirected_to(conn) == ~p"/login"
  end

  test "does not resolve another user's client session", %{conn: conn} do
    owner = user_fixture()
    other_user = user_fixture()
    {_plan, session} = saved_session(owner)

    conn =
      conn
      |> authenticated_json(other_user)
      |> post(~p"/api/session-pose-traces", upload_payload(session.client_session_id, [chunk(0)]))

    assert json_response(conn, 404) == %{"error" => "not_found"}
    assert Repo.all(PoseCaptureRun) == []
  end

  test "first batch creates one run linked to the saved session", %{conn: conn} do
    user = user_fixture()
    {plan, session} = saved_session(user)

    conn =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.client_session_id, [chunk(0), chunk(1)])
      )

    assert json_response(conn, 200) == %{
             "accepted_indexes" => [0, 1],
             "complete" => false
           }

    assert [run] = Repo.all(PoseCaptureRun)
    assert run.user_id == user.id
    assert run.plan_id == plan.id
    assert run.workout_session_id == session.id
    assert run.status == :active
    assert Enum.map(Repo.all(PoseTraceChunk), & &1.chunk_index) |> Enum.sort() == [0, 1]

    assert Repo.get_by!(PoseTraceChunk, chunk_index: 0).payload_digest ==
             :crypto.hash(:sha256, Jason.encode!(chunk(0)["payload"]))
             |> Base.encode16(case: :lower)
  end

  test "repeated payloads acknowledge existing indexes without duplicates", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = saved_session(user)
    payload = upload_payload(session.client_session_id, [chunk(0), chunk(1)])

    first = conn |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)

    second =
      conn |> recycle() |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)

    assert json_response(first, 200)["accepted_indexes"] == [0, 1]
    assert json_response(second, 200)["accepted_indexes"] == [0, 1]
    assert Repo.aggregate(PoseCaptureRun, :count) == 1
    assert Repo.aggregate(PoseTraceChunk, :count) == 2
  end

  test "client supplied digest is ignored in favor of the stored payload digest", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = saved_session(user)
    poisoned_chunk = Map.put(chunk(0), "payload_digest", "client-supplied")

    conn =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.client_session_id, [poisoned_chunk])
      )

    assert json_response(conn, 200)["accepted_indexes"] == [0]
    refute Repo.get_by!(PoseTraceChunk, chunk_index: 0).payload_digest == "client-supplied"
  end

  test "changed duplicate payload returns conflict and rolls back the whole batch", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = saved_session(user)

    first =
      conn
      |> authenticated_json(user)
      |> post(~p"/api/session-pose-traces", upload_payload(session.client_session_id, [chunk(0)]))

    assert json_response(first, 200)["accepted_indexes"] == [0]

    changed_duplicate = put_in(chunk(0), ["payload", "samples"], [%{"tMs" => 999}])

    conflict =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.client_session_id, [chunk(1), changed_duplicate])
      )

    assert json_response(conflict, 409) == %{"error" => "chunk_conflict"}
    assert Repo.all(PoseTraceChunk) |> Enum.map(& &1.chunk_index) == [0]
  end

  test "unresolved lifecycle session cannot receive deferred traces", %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(user)
    client_session_id = Ecto.UUID.generate()
    assert {:ok, _session} = Workouts.begin_plan_session(user, plan, client_session_id)

    conn =
      conn
      |> authenticated_json(user)
      |> post(~p"/api/session-pose-traces", upload_payload(client_session_id, [chunk(0)]))

    assert json_response(conn, 404) == %{"error" => "not_found"}
    assert Repo.all(PoseCaptureRun) == []
  end

  test "final batch marks the existing run completed", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = saved_session(user)

    conn
    |> authenticated_json(user)
    |> post(~p"/api/session-pose-traces", upload_payload(session.client_session_id, [chunk(0)]))

    final_conn =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.client_session_id, [chunk(1)], true)
      )

    assert json_response(final_conn, 200) == %{
             "accepted_indexes" => [1],
             "complete" => true
           }

    assert [run] = Repo.all(PoseCaptureRun)
    assert run.status == :completed
    assert run.completed_at
    assert Repo.aggregate(PoseTraceChunk, :count) == 2

    completed_at = ~U[2026-01-01 00:00:00Z]
    Repo.update_all(PoseCaptureRun, set: [completed_at: completed_at])

    repeated_conn =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.client_session_id, [chunk(1)], true)
      )

    assert json_response(repeated_conn, 200) == %{
             "accepted_indexes" => [1],
             "complete" => true
           }

    assert Repo.get!(PoseCaptureRun, run.id).completed_at == completed_at
    assert Repo.aggregate(PoseCaptureRun, :count) == 1
    assert Repo.aggregate(PoseTraceChunk, :count) == 2
  end

  test "bounded near-limit request ingests and idempotently acknowledges all chunk indexes", %{
    conn: conn
  } do
    user = user_fixture()
    {_plan, session} = saved_session(user)

    payload =
      upload_payload(
        session.client_session_id,
        Enum.map(0..2, &near_limit_chunk/1)
      )

    assert byte_size(Jason.encode!(payload)) <= 512 * 1024

    first = conn |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)

    second =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(~p"/api/session-pose-traces", payload)

    assert json_response(first, 200)["accepted_indexes"] == [0, 1, 2]
    assert json_response(second, 200)["accepted_indexes"] == [0, 1, 2]
    assert Repo.aggregate(PoseCaptureRun, :count) == 1
    assert Repo.aggregate(PoseTraceChunk, :count) == 3
  end

  test "invalid oversized chunk rolls back run creation and leaves session unchanged", %{
    conn: conn
  } do
    user = user_fixture()
    {_plan, session} = saved_session(user)
    before = Repo.reload(session)

    oversized =
      chunk(0)
      |> put_in(["payload", "samples"], [
        %{"tMs" => 0, "blob" => String.duplicate("x", 250_001)}
      ])

    conn =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.client_session_id, [oversized])
      )

    assert %{"errors" => %{"payload_json" => ["is too large"]}} = json_response(conn, 422)
    assert Repo.reload(session) == before
    assert Repo.all(PoseCaptureRun) == []
    assert Repo.all(PoseTraceChunk) == []
  end

  defp saved_session(user) do
    plan = plan_fixture(user)
    client_session_id = Ecto.UUID.generate()

    assert {:ok, _session} = Workouts.begin_plan_session(user, plan, client_session_id)

    assert {:ok, session, :reported} =
             Workouts.report_session(
               user,
               client_session_id,
               %{
                 "burpee_count_actual" => 30,
                 "duration_sec_actual" => 120
               },
               %{}
             )

    {plan, session}
  end

  defp authenticated_json(conn, user) do
    conn
    |> init_test_session(%{user_id: user.id})
    |> put_req_header("accept", "application/json")
  end

  defp upload_payload(client_session_id, chunks, complete \\ false) do
    %{
      "client_session_id" => client_session_id,
      "chunks" => chunks,
      "complete" => complete
    }
  end

  defp near_limit_chunk(index) do
    chunk(index)
    |> put_in(["payload", "samples"], [
      %{"tMs" => index * 1_000, "blob" => String.duplicate("x", 170_000)}
    ])
  end

  defp chunk(index) do
    %{
      "segment" => "main",
      "chunk_index" => index,
      "started_at_ms" => index * 1_000,
      "ended_at_ms" => (index + 1) * 1_000,
      "sample_count" => 1,
      "payload" => %{
        "version" => 1,
        "samples" => [%{"tMs" => index * 1_000}]
      }
    }
  end
end
