defmodule BurpeeTrainer.Coach.DraftAuthoringTest do
  use BurpeeTrainer.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan}

  @max_response_bytes 262_144

  setup do
    counter = start_supervised!({Agent, fn -> %{count: 0, requests: []} end})
    %{counter: counter}
  end

  test "valid create performs one request and persists one validated draft", %{counter: counter} do
    user = user_fixture()
    definition = definition("Generated draft")
    req = request(counter, &provider_definition(&1, definition))

    assert {:ok, draft} = Coach.create_draft(user, "Build a steady workout", opts(req))
    assert request_count(counter) == 1
    assert Enum.map(Workouts.list_drafts(user), & &1.id) == [draft.id]
    assert draft.state == :draft
    assert draft.origin == :user
    assert draft.request_text == "Build a steady workout"
    assert draft.definition_json == definition
    assert draft.name == "Generated draft"
    assert draft.burpee_type == :six_count
    assert draft.target_reps == 10
    assert draft.target_duration_sec == 120
    refute draft.program_json == %{}
    assert is_binary(draft.content_hash)

    [recorded] = requests(counter)
    assert recorded.body["max_tokens"] == 16_384

    [system_message, user_message] = recorded.body["messages"]

    assert system_message["content"] =~
             ~r/sum of reps across\s+every work event must equal target_reps/i

    assert system_message["content"] =~
             ~r/when the user requests\s+no rest, events must contain no rest events/i

    assert user_message["content"] == "Build a steady workout"
  end

  test "failed create logs only safe provider diagnostics", %{counter: counter} do
    user = user_fixture()
    request_text = "private workout request"
    raw_body = "private provider response"
    req = request(counter, &Plug.Conn.send_resp(&1, 503, raw_body))

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %Error{code: :provider_unavailable}} =
                 Coach.create_draft(user, request_text, req: req, config: provider_config())
      end)

    assert log =~ "workout_draft_create_failed"
    assert log =~ "error_code=provider_unavailable"
    assert log =~ "provider_status=503"
    refute log =~ request_text
    refute log =~ raw_body
  end

  test "invalid provider workout logs safe validation diagnostics", %{counter: counter} do
    user = user_fixture()

    invalid_definition =
      put_in(definition("Invalid arithmetic"), ["events", Access.at(0), "reps"], 9)

    req = request(counter, &provider_definition(&1, invalid_definition))

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %Error{code: :invalid_workout_definition}} =
                 Coach.create_draft(user, "private request", opts(req))
      end)

    assert log =~ "workout_definition_rejected"
    assert log =~ "phase=schema"
    assert log =~ "field=target_reps"
    assert log =~ "actual=9 expected=10"
    refute log =~ "private request"
    refute log =~ "Invalid arithmetic"
  end

  test "create rejects blank and over-limit authoring input before HTTP", %{counter: counter} do
    user = user_fixture()
    req = request(counter, &provider_definition(&1, definition("must not persist")))

    invalid_inputs = [
      " \n\t ",
      String.duplicate("a", 501),
      String.duplicate("e\u0301", 501),
      String.duplicate("👍🏽", 499) <> "👨‍👩‍👧‍👦"
    ]

    for input <- invalid_inputs do
      assert {:error, %Error{code: :invalid_workout_definition, context: %{}}} =
               Coach.create_draft(user, input, opts(req))
    end

    assert request_count(counter) == 0
    assert Workouts.list_drafts(user) == []
  end

  test "create trims and accepts grapheme and byte boundaries", %{counter: counter} do
    user = user_fixture()
    req = request(counter, &provider_definition(&1, definition("Boundary draft")))

    inputs = [
      {"  " <> String.duplicate("a", 500) <> " \n", String.duplicate("a", 500)},
      {String.duplicate("e\u0301", 500), String.duplicate("e\u0301", 500)},
      {String.duplicate("👍🏽", 500), String.duplicate("👍🏽", 500)}
    ]

    for {input, expected_request} <- inputs do
      assert {:ok, %WorkoutPlan{request_text: ^expected_request}} =
               Coach.create_draft(user, input, opts(req))
    end

    assert byte_size(elem(List.last(inputs), 1)) == 4_000
    assert request_count(counter) == 3
    assert length(Workouts.list_drafts(user)) == 3
  end

  test "all failed create boundaries persist nothing and never retry", %{counter: counter} do
    user = user_fixture()

    scenarios = [
      {:disabled, request(counter, &provider_definition(&1, definition("unused"))),
       [enabled: false], :provider_unavailable, 0},
      {:missing_credentials, request(counter, &provider_definition(&1, definition("unused"))),
       [enabled: true, url: "https://provider.test/v1", model: "test/model"],
       :provider_unavailable, 0},
      {:timeout, request(counter, &Req.Test.transport_error(&1, :timeout)), provider_config(),
       :provider_timeout, 1},
      {:redirect,
       request(counter, fn conn ->
         conn
         |> Plug.Conn.put_resp_header("location", "https://provider.test/redirected")
         |> Plug.Conn.send_resp(302, "redirect body")
       end), provider_config(), :provider_unavailable, 1},
      {:status, request(counter, &Plug.Conn.send_resp(&1, 503, "raw provider failure body")),
       provider_config(), :provider_unavailable, 1},
      {:malformed_envelope, request(counter, &Plug.Conn.send_resp(&1, 200, Jason.encode!(%{}))),
       provider_config(), :invalid_provider_response, 1},
      {:invalid_json,
       request(counter, fn conn ->
         Plug.Conn.send_resp(
           conn,
           200,
           Jason.encode!(%{"choices" => [%{"message" => %{"content" => "not-json"}}]})
         )
       end), provider_config(), :invalid_provider_response, 1},
      {:oversized,
       request(
         counter,
         &Plug.Conn.send_resp(&1, 200, String.duplicate("x", @max_response_bytes + 1))
       ), provider_config(), :invalid_provider_response, 1},
      {:chunked_oversized,
       request(counter, fn conn ->
         chunk = String.duplicate("x", div(@max_response_bytes, 2) + 1)
         conn = Plug.Conn.send_chunked(conn, 200)
         {:ok, conn} = Plug.Conn.chunk(conn, chunk)
         {:ok, conn} = Plug.Conn.chunk(conn, chunk)
         conn
       end), provider_config(), :invalid_provider_response, 1},
      {:invalid_definition, request(counter, &provider_definition(&1, %{"version" => 1})),
       provider_config(), :invalid_workout_definition, 1},
      {:infeasible_definition,
       request(counter, &provider_definition(&1, definition(String.duplicate("n", 81)))),
       provider_config(), :infeasible_workout_definition, 1}
    ]

    Enum.reduce(scenarios, 0, fn {label, req, config, expected_code, expected_calls}, calls ->
      assert {:error, %Error{code: ^expected_code} = error} =
               Coach.create_draft(user, "scenario #{label}", req: req, config: config)

      refute inspect(error) =~ "raw provider failure body"
      assert Workouts.list_drafts(user) == []
      assert request_count(counter) == calls + expected_calls
      calls + expected_calls
    end)
  end

  test "refine rejects blank and over-limit authoring input before HTTP or persistence", %{
    counter: counter
  } do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user, %{definition: definition("Original")})
    before = raw_row(draft.id)
    req = request(counter, &provider_definition(&1, definition("must not persist")))

    invalid_inputs = [
      " \n\t ",
      String.duplicate("a", 501),
      String.duplicate("e\u0301", 501),
      String.duplicate("👍🏽", 499) <> "👨‍👩‍👧‍👦"
    ]

    for input <- invalid_inputs do
      assert {:error, %Error{code: :invalid_workout_definition, context: %{}}} =
               Coach.refine_draft(user, draft.id, input, opts(req))
    end

    assert request_count(counter) == 0
    assert raw_row(draft.id) == before
  end

  test "refine trims and accepts the exact multibyte boundary", %{counter: counter} do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user, %{definition: definition("Original")})
    req = request(counter, &provider_definition(&1, definition("Boundary refinement")))
    instruction = String.duplicate("👍🏽", 500)

    assert String.length(instruction) == 500
    assert byte_size(instruction) == 4_000

    assert {:ok, %WorkoutPlan{request_text: ^instruction}} =
             Coach.refine_draft(user, draft.id, "  " <> instruction <> " \n", opts(req))

    assert request_count(counter) == 1
  end

  test "refinement sends the current definition and instruction in one request", %{
    counter: counter
  } do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user, %{definition: definition("Current")})
    replacement = definition("Refined", "navy_seal", 20, 200)
    req = request(counter, &provider_definition(&1, replacement))
    instruction = "Use navy seal burpees and a shorter cadence."

    assert {:ok, refined} = Coach.refine_draft(user, draft.id, instruction, opts(req))
    assert refined.id == draft.id
    assert request_count(counter) == 1

    [recorded] = requests(counter)
    messages = recorded.body["messages"]
    refinement_message = List.last(messages)
    assert refinement_message["role"] == "user"

    assert %{
             "current_definition" => current_definition,
             "instruction" => ^instruction
           } = Jason.decode!(refinement_message["content"])

    assert current_definition == draft.definition_json
  end

  test "failed refinement leaves every persisted field byte-for-byte unchanged", %{
    counter: counter
  } do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user, %{definition: definition("Original")})
    before = raw_row(draft.id)
    invalid = Map.put(definition("Invalid"), "target_reps", 11)
    req = request(counter, &provider_definition(&1, invalid))

    assert {:error, %Error{code: :invalid_workout_definition, context: %{}}} =
             Coach.refine_draft(user, draft.id, "Break the arithmetic", opts(req))

    assert request_count(counter) == 1
    assert raw_row(draft.id) == before
  end

  test "successful refinement atomically replaces all derived content", %{counter: counter} do
    user = user_fixture()

    draft =
      workout_plan_draft_fixture(user, %{
        definition: definition("Original"),
        request_text: "original request"
      })

    replacement = definition("Atomic replacement", "navy_seal", 25, 250)
    req = request(counter, &provider_definition(&1, replacement))
    instruction = "Replace every workout fact."

    assert {:ok, refined} = Coach.refine_draft(user, draft.id, instruction, opts(req))
    assert request_count(counter) == 1
    assert refined.id == draft.id
    assert refined.request_text == instruction
    assert refined.definition_json == replacement
    assert refined.program_json != draft.program_json
    assert refined.content_hash != draft.content_hash
    assert refined.name == "Atomic replacement"
    assert refined.burpee_type == :navy_seal
    assert refined.target_reps == 25
    assert refined.target_duration_sec == 250

    persisted = Repo.get!(WorkoutPlan, draft.id)

    assert Map.take(persisted, [
             :request_text,
             :definition_json,
             :program_json,
             :content_hash,
             :name,
             :burpee_type,
             :target_reps,
             :target_duration_sec
           ]) ==
             Map.take(refined, [
               :request_text,
               :definition_json,
               :program_json,
               :content_hash,
               :name,
               :burpee_type,
               :target_reps,
               :target_duration_sec
             ])
  end

  test "concurrent refinements compare the complete draft revision before replacing", %{
    sandbox_owner: sandbox_owner
  } do
    Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner)

    state =
      outside_sandbox(fn ->
        user = user_fixture()
        draft = workout_plan_draft_fixture(user, %{definition: definition("Original")})
        %{user: user, user_id: user.id, draft: draft}
      end)

    on_exit(fn -> cleanup_committed_user(state.user_id) end)

    barrier = make_ref()
    first_instruction = "First concurrent refinement"
    second_instruction = "Second concurrent refinement"

    first =
      start_refinement_task(
        self(),
        barrier,
        :first_provider_ready,
        state.user,
        state.draft.id,
        first_instruction,
        definition("First winner")
      )

    second =
      start_refinement_task(
        self(),
        barrier,
        :second_provider_ready,
        state.user,
        state.draft.id,
        second_instruction,
        definition("Stale second")
      )

    assert_receive {:first_provider_ready, first_pid, ^barrier}, 1_000
    assert_receive {:second_provider_ready, second_pid, ^barrier}, 1_000

    send(first_pid, {:respond, barrier})
    assert {:ok, %WorkoutPlan{name: "First winner"}} = Task.await(first, 10_000)

    send(second_pid, {:respond, barrier})

    assert {:error, %Error{code: :draft_stale, context: %{}}} =
             Task.await(second, 10_000)

    persisted = outside_sandbox(fn -> Repo.get!(WorkoutPlan, state.draft.id) end)
    assert persisted.name == "First winner"
    assert persisted.request_text == first_instruction
    refute persisted.request_text == second_instruction
  end

  test "draft revisions advance monotonically and reject an ABA replacement" do
    user = user_fixture()
    stale = workout_plan_draft_fixture(user, %{definition: definition("Original")})

    assert {:ok, away} =
             Workouts.replace_draft(user, stale.id, %{
               definition: definition("Away"),
               request_text: "away"
             })

    assert DateTime.compare(away.updated_at, stale.updated_at) == :gt

    assert {:ok, restored} =
             Workouts.replace_draft(user, stale.id, %{
               definition: stale.definition_json,
               request_text: stale.request_text
             })

    assert DateTime.compare(restored.updated_at, away.updated_at) == :gt

    assert Map.take(restored, [
             :name,
             :request_text,
             :definition_json,
             :program_json,
             :content_hash,
             :burpee_type,
             :target_reps,
             :target_duration_sec
           ]) ==
             Map.take(stale, [
               :name,
               :request_text,
               :definition_json,
               :program_json,
               :content_hash,
               :burpee_type,
               :target_reps,
               :target_duration_sec
             ])

    assert {:error, %Error{code: :draft_stale, context: %{}}} =
             Workouts.replace_draft(user, stale.id, %{
               definition: definition("Must not replace restored state"),
               request_text: "stale",
               expected_revision: stale
             })
  end

  test "published archived foreign and missing drafts are rejected before HTTP", %{
    counter: counter
  } do
    owner = user_fixture()
    other_user = user_fixture()

    published_draft = workout_plan_draft_fixture(owner, %{definition: definition("Published")})
    assert {:ok, published} = Workouts.publish_draft(owner, published_draft.id)

    archived_draft = workout_plan_draft_fixture(owner, %{definition: definition("Archived")})
    assert {:ok, archived_published} = Workouts.publish_draft(owner, archived_draft.id)
    assert {:ok, archived} = Workouts.archive_plan(owner, archived_published.id)

    foreign = workout_plan_draft_fixture(other_user, %{definition: definition("Foreign")})
    req = request(counter, &provider_definition(&1, definition("must not be called")))

    for plan <- [published, archived] do
      assert {:error, %Error{code: :workout_immutable}} =
               Coach.refine_draft(owner, plan.id, "No mutation", opts(req))
    end

    assert {:error, %Error{code: :draft_not_owned}} =
             Coach.refine_draft(owner, foreign.id, "No theft", opts(req))

    assert {:error, %Error{code: :draft_not_found}} =
             Coach.refine_draft(owner, 2_147_483_647, "No missing row", opts(req))

    assert request_count(counter) == 0
  end

  defp start_refinement_task(
         test_pid,
         barrier,
         ready_tag,
         user,
         draft_id,
         instruction,
         replacement
       ) do
    Task.async(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      try do
        req =
          Req.new(
            adapter: fn request ->
              send(test_pid, {ready_tag, self(), barrier})

              receive do
                {:respond, ^barrier} ->
                  {request, %Req.Response{status: 200, body: provider_body(replacement)}}
              end
            end
          )

        Coach.refine_draft(user, draft_id, instruction, opts(req))
      after
        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end
    end)
  end

  defp outside_sandbox(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp cleanup_committed_user(user_id) do
    outside_sandbox(fn ->
      Repo.delete_all(from(plan in WorkoutPlan, where: plan.user_id == ^user_id))
      Repo.delete_all(from(user in User, where: user.id == ^user_id))
    end)
  end

  defp request(counter, responder) do
    Req.new(
      plug: fn conn ->
        Agent.update(counter, fn state ->
          recorded = %{body: conn.body_params, path: conn.request_path}
          %{state | count: state.count + 1, requests: [recorded | state.requests]}
        end)

        responder.(conn)
      end
    )
  end

  defp provider_definition(conn, definition) do
    Plug.Conn.send_resp(conn, 200, provider_body(definition))
  end

  defp provider_body(definition) do
    Jason.encode!(%{
      "choices" => [%{"message" => %{"content" => Jason.encode!(definition)}}]
    })
  end

  defp opts(req), do: [req: req, config: provider_config()]

  defp provider_config do
    [
      enabled: true,
      url: "https://provider.test/v1/chat/completions",
      api_key: "test-secret",
      model: "test/model",
      timeout_ms: 12_345
    ]
  end

  defp request_count(counter), do: Agent.get(counter, & &1.count)
  defp requests(counter), do: Agent.get(counter, &Enum.reverse(&1.requests))

  defp raw_row(id) do
    result = Repo.query!("SELECT * FROM workout_plans WHERE id = ?", [id])
    {result.columns, result.rows}
  end

  defp definition(name, burpee_type \\ "six_count", target_reps \\ 10, duration \\ 120) do
    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => burpee_type,
      "target_reps" => target_reps,
      "target_duration_sec" => duration,
      "pacing_style" => "even",
      "events" => [
        %{
          "kind" => "work",
          "reps" => target_reps,
          "sec_per_rep" => duration / target_reps,
          "sec_per_burpee" => duration / target_reps
        }
      ],
      "rationale" => "A deterministic draft-authoring fixture."
    }
  end
end
