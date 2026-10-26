defmodule BurpeeTrainerWeb.PoseTraceUploadControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk}

  test "requires an authenticated user", %{conn: conn} do
    conn = post(conn, ~p"/api/session-pose-traces", %{"session_id" => 1})
    assert json_response(conn, 401) == %{"error" => "authentication_required"}
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
    {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

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

  test "an uploaded chunk is stored gzipped and reads back as it was sent", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)

    conn
    |> authenticated_json(user)
    |> post(
      ~p"/api/session-pose-traces",
      upload_payload(session.id, session.client_session_id, [chunk(0)], true)
    )
    |> json_response(200)

    [[stored]] = Repo.query!("SELECT payload_json FROM pose_trace_chunks").rows
    assert :zlib.gunzip(stored) == Jason.encode!(chunk(0)["payload"])

    assert [%PoseTraceChunk{payload_json: json}] = Repo.all(PoseTraceChunk)
    assert Jason.decode!(json) == chunk(0)["payload"]
  end

  test "real recorded pose frames survive a JSON upload and an exact retry", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)

    samples =
      "assets/js/hooks/fixtures/pose_burpee_session_140_reps.json.gz"
      |> File.read!()
      |> :zlib.gunzip()
      |> Jason.decode!()
      |> Map.fetch!("samples")
      |> Enum.take(10)

    recorded = %{
      "segment" => "main",
      "chunk_index" => 0,
      "started_at_ms" => hd(samples)["tMs"],
      "ended_at_ms" => List.last(samples)["tMs"],
      "sample_count" => length(samples),
      "payload" => %{"version" => 1, "samples" => samples}
    }

    body =
      upload_payload(session.id, session.client_session_id, [recorded], true) |> Jason.encode!()

    for _attempt <- 1..2 do
      response =
        conn
        |> recycle()
        |> authenticated_json(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/session-pose-traces", body)

      assert json_response(response, 200) == %{"accepted_indexes" => [0], "complete" => true}
    end

    assert [%PoseTraceChunk{payload_json: payload, sample_count: 10}] = Repo.all(PoseTraceChunk)
    assert Jason.decode!(payload)["samples"] == samples
    assert Repo.one!(PoseCaptureRun).status == :completed
  end

  test "final completion requires the declared last chunk and no extras", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)
    scope = Scope.for_user(user)

    assert {:ok, _} =
             Workouts.ingest_pose_trace_batch(
               scope,
               session.id,
               session.client_session_id,
               [chunk(0)],
               false
             )

    for {chunks, total} <- [{[chunk(1)], 3}, {[chunk(1)], 1}] do
      payload =
        upload_payload(session.id, session.client_session_id, chunks, true)
        |> Map.put("expected_chunk_count", total)

      response =
        conn
        |> recycle()
        |> authenticated_json(user)
        |> post(~p"/api/session-pose-traces", payload)

      assert json_response(response, 422) == %{"errors" => %{"batch" => ["is invalid"]}}
      assert Repo.one!(PoseCaptureRun).status == :active
      assert Repo.aggregate(PoseTraceChunk, :count) == 1
    end

    payload =
      upload_payload(session.id, session.client_session_id, [chunk(1)], true)
      |> Map.put("expected_chunk_count", 2)

    response =
      conn |> recycle() |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)

    assert json_response(response, 200) == %{"accepted_indexes" => [1], "complete" => true}
    assert Repo.aggregate(PoseTraceChunk, :count) == 2
  end

  test "a manifest completes despite chunks the device never wrote", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)

    payload =
      upload_payload(session.id, session.client_session_id, [chunk(0), chunk(2)], true)
      |> Map.put("expected_chunk_count", 3)

    response =
      conn |> authenticated_json(user) |> post(~p"/api/session-pose-traces", payload)

    assert json_response(response, 200) == %{"accepted_indexes" => [0, 2], "complete" => true}
    assert Repo.one!(PoseCaptureRun).status == :completed
  end

  test "legacy completion also refuses gaps", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)

    response =
      conn
      |> authenticated_json(user)
      |> post(
        ~p"/api/session-pose-traces",
        upload_payload(session.id, session.client_session_id, [chunk(2)], true)
      )

    assert json_response(response, 422) == %{"errors" => %{"batch" => ["is invalid"]}}
    assert Repo.all(PoseCaptureRun) == []
  end

  test "gzip JSON uploads are decoded before validation and stored normally", %{conn: conn} do
    user = user_fixture()
    {_plan, session} = completed_session(user)

    body =
      upload_payload(session.id, session.client_session_id, [chunk(0)], true)
      |> Map.put("expected_chunk_count", 1)
      |> Jason.encode!()
      |> :zlib.gzip()

    response =
      conn
      |> authenticated_json(user)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-encoding", "gzip")
      |> post(~p"/api/session-pose-traces", body)

    assert json_response(response, 200) == %{"accepted_indexes" => [0], "complete" => true}
    assert Repo.one!(PoseCaptureRun).status == :completed
    assert Jason.decode!(Repo.one!(PoseTraceChunk).payload_json) == chunk(0)["payload"]
  end

  test "gzip decoding rejects malformed, truncated and oversized decompressed bodies", %{
    conn: conn
  } do
    user = user_fixture()
    {_plan, session} = completed_session(user)

    valid =
      upload_payload(session.id, session.client_session_id, [chunk(0)], true)
      |> Jason.encode!()
      |> :zlib.gzip()

    for body <- ["not gzip", binary_part(valid, 0, byte_size(valid) - 4)] do
      assert_error_sent 400, fn ->
        conn
        |> recycle()
        |> authenticated_json(user)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-encoding", "gzip")
        |> post(~p"/api/session-pose-traces", body)
      end
    end

    for {body, encoding} <- [
          {String.duplicate("x", 4 * 1024 * 1024 + 1), nil},
          {String.duplicate("x", 4 * 1024 * 1024 + 1) |> :zlib.gzip(), "gzip"}
        ] do
      assert_error_sent 413, fn ->
        request =
          conn
          |> recycle()
          |> authenticated_json(user)
          |> put_req_header("content-type", "application/json")

        request =
          if encoding, do: put_req_header(request, "content-encoding", encoding), else: request

        post(request, ~p"/api/session-pose-traces", body)
      end
    end

    assert Repo.all(PoseCaptureRun) == []
  end

  defp completed_session(user) do
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    {:ok, completed} =
      Workouts.complete_session(
        Scope.for_user(user),
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
