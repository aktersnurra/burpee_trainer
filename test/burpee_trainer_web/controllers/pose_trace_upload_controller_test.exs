defmodule BurpeeTrainerWeb.PoseTraceUploadControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk}

  test "requires an authenticated user", %{conn: conn} do
    conn = post(conn, ~p"/api/session-pose-traces", %{"session_id" => 1})
    assert redirected_to(conn) == ~p"/login"
  end

  test "requires one exact owned session ID and client ID", %{conn: conn} do
    owner = user_fixture()
    intruder = user_fixture()
    {_plan, session} = completed_session(owner)

    for {user, session_id, client_id} <- [
          {intruder, session.id, session.client_session_id},
          {owner, session.id, Ecto.UUID.generate()},
          {owner, 2_147_483_647, session.client_session_id}
        ] do
      response =
        conn
        |> recycle()
        |> authenticated_json(user)
        |> post(~p"/api/session-pose-traces", upload_payload(session_id, client_id, [chunk(0)]))

      assert json_response(response, 404) == %{"error" => "not_found"}
    end

    assert Repo.all(PoseCaptureRun) == []
  end

  test "started sessions reject deferred evidence without persisting it", %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    response =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(started.id, started.client_session_id, [chunk(0)], true)
      )

    assert json_response(response, 404) == %{"error" => "not_found"}
    assert Repo.all(PoseCaptureRun) == []
    assert Repo.all(PoseTraceChunk) == []
  end

  test "batches create one session-bound run, deduplicate chunks, and complete", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)
    first_payload = upload_payload(session.id, session.client_session_id, [chunk(0), chunk(1)])

    first = conn |> authenticated_json(user) |> post(~p"/api/session-pose-traces", first_payload)

    repeated =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(~p"/api/session-pose-traces", first_payload)

    final =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [chunk(2)], true)
      )

    assert json_response(first, 200) == %{
             "accepted_indexes" => [0, 1],
             "complete" => false
           }

    finalized_at = Repo.one!(PoseCaptureRun).completed_at

    final_replay =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [chunk(2)], true)
      )

    new_after_final =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [chunk(3)], true)
      )

    assert json_response(repeated, 200)["accepted_indexes"] == [0, 1]
    assert json_response(final, 200) == %{"accepted_indexes" => [2], "complete" => true}
    assert json_response(final_replay, 200) == %{"accepted_indexes" => [2], "complete" => true}
    assert json_response(new_after_final, 422) == %{"errors" => %{"batch" => ["is invalid"]}}

    assert [run] = Repo.all(PoseCaptureRun)
    assert run.user_id == user.id
    assert run.workout_session_id == session.id
    assert run.status == :completed
    assert run.completed_at == finalized_at
    assert Repo.aggregate(PoseTraceChunk, :count) == 3

    for stored <- Repo.all(PoseTraceChunk) do
      expected =
        :crypto.hash(:sha256, stored.payload_json)
        |> Base.encode16(case: :lower)

      assert stored.payload_digest == expected
    end
  end

  test "active runs accept exact retry and reject conflicting same-index content", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)
    payload = upload_payload(session.id, session.client_session_id, [chunk(0)])

    first = conn |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)
    stored = Repo.get_by!(PoseTraceChunk, chunk_index: 0)

    exact_retry =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(~p"/api/session-pose-traces", payload)

    conflicting =
      chunk(0)
      |> put_in(["payload", "samples"], [%{"tMs" => 0, "changed" => true}])

    conflict =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [conflicting])
      )

    assert json_response(first, 200)["accepted_indexes"] == [0]
    assert json_response(exact_retry, 200)["accepted_indexes"] == [0]
    assert json_response(conflict, 422) == %{"errors" => %{"batch" => ["is invalid"]}}
    assert immutable_chunk_fields(Repo.reload(stored)) == immutable_chunk_fields(stored)
  end

  test "completed runs accept exact retry and reject conflicting immutable metadata", %{
    conn: conn
  } do
    user = user_fixture()
    {_plan, session} = completed_session(user)
    payload = upload_payload(session.id, session.client_session_id, [chunk(0)], true)

    first = conn |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)
    stored = Repo.get_by!(PoseTraceChunk, chunk_index: 0)
    completed_at = Repo.one!(PoseCaptureRun).completed_at

    exact_retry =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(~p"/api/session-pose-traces", payload)

    conflicting =
      chunk(0)
      |> Map.put("segment", "warmup")
      |> Map.put("ended_at_ms", 2_000)
      |> put_in(["payload", "samples"], [%{"tMs" => 0, "changed" => true}])

    conflict =
      conn
      |> recycle()
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [conflicting], true)
      )

    assert json_response(first, 200) == %{"accepted_indexes" => [0], "complete" => true}
    assert json_response(exact_retry, 200) == %{"accepted_indexes" => [0], "complete" => true}
    assert json_response(conflict, 422) == %{"errors" => %{"batch" => ["is invalid"]}}
    assert Repo.one!(PoseCaptureRun).completed_at == completed_at
    assert immutable_chunk_fields(Repo.reload(stored)) == immutable_chunk_fields(stored)
  end

  test "client payload digest is ignored in favor of the server-computed digest", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)
    poisoned = Map.put(chunk(0), "payload_digest", "client-supplied")

    response =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [poisoned])
      )

    assert json_response(response, 200)["accepted_indexes"] == [0]
    stored = Repo.get_by!(PoseTraceChunk, chunk_index: 0)
    refute stored.payload_digest == "client-supplied"
  end

  test "invalid chunk rolls back run creation and leaves the completed session unchanged", %{
    conn: conn
  } do
    user = user_fixture()
    {_plan, session} = completed_session(user)
    before = Repo.reload(session)

    oversized =
      chunk(0)
      |> put_in(["payload", "samples"], [
        %{"tMs" => 0, "blob" => String.duplicate("x", 250_001)}
      ])

    response =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [oversized])
      )

    assert %{"errors" => %{"payload_json" => ["is too large"]}} = json_response(response, 422)
    assert Repo.reload(session) == before
    assert Repo.all(PoseCaptureRun) == []
    assert Repo.all(PoseTraceChunk) == []
  end

  defp completed_session(user) do
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    {:ok, completed} =
      Workouts.complete_session(
        user,
        started.id,
        %{"burpee_count_actual" => 30, "duration_sec_actual" => 120},
        :timed
      )

    {plan, completed}
  end

  defp authenticated_json(conn, user) do
    conn
    |> init_test_session(%{user_id: user.id})
    |> put_req_header("accept", "application/json")
  end

  defp upload_payload(session_id, client_session_id, chunks, complete \\ false) do
    %{
      "session_id" => session_id,
      "client_session_id" => client_session_id,
      "chunks" => chunks,
      "complete" => complete
    }
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

  defp immutable_chunk_fields(chunk) do
    Map.take(chunk, [
      :segment,
      :chunk_index,
      :started_at_ms,
      :ended_at_ms,
      :sample_count,
      :payload_json,
      :payload_digest
    ])
  end
end
