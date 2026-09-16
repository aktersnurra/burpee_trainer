defmodule BurpeeTrainer.Coach.DraftAuthoringTest do
  use BurpeeTrainer.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Coach.{Context, DesignEntry}
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.{Error, WorkoutPlan}

  @max_response_bytes 262_144

  setup do
    counter = start_supervised!({Agent, fn -> %{count: 0, requests: []} end})
    %{counter: counter}
  end

  test "direct draft creation requires an explicitly confirmed prepared request", %{
    counter: counter
  } do
    user = user_fixture()

    extracted = %{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    extraction = request(counter, &provider_definition(&1, extracted))
    assert {:ok, prepared} = Coach.prepare_draft(user, "Build a steady workout", opts(extraction))
    assert request_count(counter) == 1
    assert Workouts.list_drafts(user) == []

    plan = request(counter, &provider_definition(&1, definition("Confirmed draft")))
    assert {:ok, draft} = Coach.confirm_draft(user, prepared, opts(plan))
    assert draft.name == "Confirmed draft"
    assert request_count(counter) == 2
  end

  test "direct draft refinement also waits for explicit confirmation", %{counter: counter} do
    user = user_fixture()
    source = workout_plan_draft_fixture(user, %{definition: definition("Original")})

    extracted = %{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    extraction = request(counter, &provider_definition(&1, extracted))

    assert {:ok, prepared} =
             Coach.prepare_refinement(user, source.id, "Make it better", opts(extraction))

    assert request_count(counter) == 1
    assert Workouts.get_plan!(user, source.id).name == "Original"

    plan = request(counter, &provider_definition(&1, definition("Confirmed refinement")))
    assert {:ok, revised} = Coach.confirm_refinement(user, prepared, opts(plan))
    assert revised.name == "Confirmed refinement"
    assert request_count(counter) == 2
    assert Workouts.get_plan!(user, source.id).name == "Confirmed refinement"
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

    [system_message, global_message, user_message] = recorded.body["messages"]

    assert system_message["content"] =~
             ~r/sum of reps across\s+every work event must equal target_reps/i

    assert system_message["content"] =~
             ~r/when the user requests\s+no rest, events must contain no rest events/i

    assert Jason.decode!(global_message["content"])["scope"] == "global"

    assert Jason.decode!(user_message["content"])["active_attempt"]["instruction"] ==
             "Build a steady workout"
  end

  test "draft authoring receives level landmarks and bounded measured history", %{
    counter: counter
  } do
    user = user_fixture()

    free_form_session_fixture(user, %{
      "burpee_count_actual" => 12,
      "duration_sec_actual" => 150,
      "note_post" => "session-only private context"
    })

    req = request(counter, &provider_definition(&1, definition("Measured draft")))
    assert {:ok, _draft} = Coach.create_draft(user, "Build a suitable workout", opts(req))

    [recorded] = requests(counter)
    [system_message, _, _] = recorded.body["messages"]
    assert system_message["content"] =~ "level_1b"
    assert system_message["content"] =~ ~s("actual_reps":12)
    assert system_message["content"] =~ ~s("actual_duration_sec":150)
    refute system_message["content"] =~ "session-only private context"
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

  test "one invalid timeline gets a logged, precise correction then commits once", %{
    counter: counter
  } do
    user = user_fixture()

    invalid =
      definition("Missing ninety seconds")
      |> put_in(["events", Access.at(0), "sec_per_rep"], 3.0)
      |> put_in(["events", Access.at(0), "sec_per_burpee"], 3.0)

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, invalid),
          else: provider_definition(conn, definition("Corrected timeline"))
      end)

    assert {:ok, draft} = Coach.create_draft(user, "Use manageable sets", opts(req))
    assert draft.name == "Corrected timeline"
    assert request_count(counter) == 2

    [_first, correction] = requests(counter)
    correction_message = List.last(correction.body["messages"])["content"]
    assert correction_message =~ "Use manageable sets"
    assert correction_message =~ "30000000"
    assert correction_message =~ "120000000"
    assert correction_message =~ "missing_duration_sec=90"
    assert correction_message =~ "work_reps=10 target_reps=10"
    assert correction_message =~ "work_sec=30 rest_sec=0"
    assert correction_message =~ "missing_sec=90"
    assert correction_message =~ "rest_events=0"

    assert {:ok, entries} = Context.entries(user, draft.design_session_id)
    assert Enum.count(entries, &(&1.kind == :proposal)) == 2
    assert Enum.count(entries, &(&1.kind == :instruction)) == 2
    assert Enum.any?(entries, &(&1.kind == :outcome and &1.payload["status"] == "failed"))
    assert Enum.any?(entries, &(&1.kind == :outcome and &1.payload["status"] == "accepted"))
  end

  test "correction sees reps, work time, rest deficit, and the target-rep rest budget together",
       %{
         counter: counter
       } do
    user = user_fixture()

    invalid =
      definition("All work")
      |> Map.put("target_reps", 140)
      |> Map.put("target_duration_sec", 1_200)
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "work", "reps" => 83, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ])

    corrected =
      invalid
      |> Map.put("name", "Recovery between sets")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 500},
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ])

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, invalid),
          else: provider_definition(conn, corrected)
      end)

    assert {:ok, draft} =
             Coach.create_draft(
               user,
               "140 six-counts in 20 minutes with rest between sets",
               opts(req)
             )

    assert request_count(counter) == 2
    assert Enum.any?(draft.definition_json["events"], &(&1["kind"] == "rest"))
    [_first, correction] = requests(counter)
    feedback = correction.body["messages"] |> List.last() |> Map.fetch!("content")
    assert feedback =~ "field=target_reps actual=153 expected=140"
    assert feedback =~ "work_reps=153 target_reps=140"
    assert feedback =~ "work_sec=765"
    assert feedback =~ "rest_sec=0"
    assert feedback =~ "missing_sec=435"
    assert feedback =~ "rest_budget_at_target_reps_sec=500"
    assert feedback =~ "adjacent_work_sets_without_rest=1"
    assert feedback =~ "allocate remaining time to explicit between-set rest"
  end

  test "correction budget uses compiler terminal work and fractional rest timing", %{
    counter: counter
  } do
    user = user_fixture()

    invalid =
      definition("Fractional gap")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 4.5},
        %{"kind" => "rest", "duration_sec" => 20},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 4.5}
      ])

    corrected =
      invalid
      |> Map.put("name", "Fractional recovery")
      |> put_in(["events", Access.at(1), "duration_sec"], 70.5)

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, invalid),
          else: provider_definition(conn, corrected)
      end)

    assert {:ok, _draft} = Coach.create_draft(user, "Two sets with rest", opts(req))
    assert request_count(counter) == 2
    [_first, correction] = requests(counter)
    feedback = correction.body["messages"] |> List.last() |> Map.fetch!("content")
    assert feedback =~ "work_sec=49.5 rest_sec=20"
    assert feedback =~ "accounted_sec=69.5 missing_sec=50.5"
    assert feedback =~ "rest_budget_at_target_reps_sec=70.5"
    assert feedback =~ "rest_events=1"
    refute feedback =~ "Correct the rep count first"
  end

  test "excess time asks for less flexible rest rather than more rest", %{counter: counter} do
    user = user_fixture()

    invalid =
      definition("Excess recovery")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 80},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ])

    corrected = put_in(invalid, ["events", Access.at(1), "duration_sec"], 70)

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, invalid),
          else: provider_definition(conn, corrected)
      end)

    assert {:ok, _draft} = Coach.create_draft(user, "Two sets with rest", opts(req))
    assert request_count(counter) == 2
    [_first, correction] = requests(counter)
    feedback = correction.body["messages"] |> List.last() |> Map.fetch!("content")
    assert feedback =~ "excess_sec=10"
    assert feedback =~ "reduce flexible rest"
    refute feedback =~ "allocate remaining time"
  end

  test "no-rest correction does not instruct the model to insert recovery", %{counter: counter} do
    user = user_fixture()

    invalid =
      definition("Short continuous work")
      |> put_in(["events", Access.at(0), "sec_per_rep"], 3)
      |> put_in(["events", Access.at(0), "sec_per_burpee"], 3)

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, invalid),
          else: provider_definition(conn, definition("Continuous work"))
      end)

    assert {:ok, _draft} = Coach.create_draft(user, "One set with no rest", opts(req))
    assert request_count(counter) == 2
    [_first, correction] = requests(counter)
    feedback = correction.body["messages"] |> List.last() |> Map.fetch!("content")
    validation = Jason.decode!(feedback)["validation"]
    assert validation =~ "do not add rest events"
    refute validation =~ "allocate remaining time to explicit between-set rest events"
  end

  test "a rest-requested unbroken workout cannot commit without rest events", %{counter: counter} do
    user = user_fixture()

    invalid =
      definition("False rest")
      |> Map.put("pacing_style", "unbroken")
      |> Map.put("rationale", "Rest between the two unbroken sets")

    corrected =
      invalid
      |> Map.put("name", "Rest between sets")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0},
        %{"kind" => "rest", "duration_sec" => 70.0},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0}
      ])

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, invalid),
          else: provider_definition(conn, corrected)
      end)

    assert {:ok, draft} =
             Coach.create_draft(
               user,
               "No rest between reps within a set; rest between the two sets",
               opts(req)
             )

    assert request_count(counter) == 2
    assert Enum.any?(draft.definition_json["events"], &(&1["kind"] == "rest"))
    [_first, correction] = requests(counter)
    assert List.last(correction.body["messages"])["content"] =~ "rest events"
  end

  test "requested recovery separates each unbroken work set", %{counter: counter} do
    user = user_fixture()

    incomplete =
      definition("One break for three sets")
      |> Map.put("pacing_style", "unbroken")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 3, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0},
        %{"kind" => "rest", "duration_sec" => 70.0},
        %{"kind" => "work", "reps" => 3, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0},
        %{"kind" => "work", "reps" => 4, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0}
      ])

    corrected =
      Map.put(incomplete, "events", [
        %{"kind" => "work", "reps" => 3, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0},
        %{"kind" => "rest", "duration_sec" => 50.0},
        %{"kind" => "work", "reps" => 3, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0},
        %{"kind" => "rest", "duration_sec" => 20.0},
        %{"kind" => "work", "reps" => 4, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0}
      ])

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, incomplete),
          else: provider_definition(conn, corrected)
      end)

    assert {:ok, draft} =
             Coach.create_draft(user, "Three unbroken sets with recovery between sets", opts(req))

    assert request_count(counter) == 2
    assert Enum.count(draft.definition_json["events"], &(&1["kind"] == "rest")) == 2
  end

  test "a no-rest instruction still allows a continuous work event", %{counter: counter} do
    user = user_fixture()
    req = request(counter, &provider_definition(&1, definition("Continuous work")))

    assert {:ok, draft} = Coach.create_draft(user, "One unbroken set with no rest", opts(req))
    assert request_count(counter) == 1
    refute Enum.any?(draft.definition_json["events"], &(&1["kind"] == "rest"))
  end

  test "an explicitly requested slower movement pace is honored", %{counter: counter} do
    user = user_fixture()

    manual =
      definition("User-paced sets")
      |> Map.put("pacing_style", "unbroken")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 8.0, "sec_per_burpee" => 8.0},
        %{"kind" => "rest", "duration_sec" => 40.0},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 8.0, "sec_per_burpee" => 8.0}
      ])

    req = request(counter, &provider_definition(&1, manual))

    assert {:ok, draft} =
             Coach.create_draft(user, "Use 8 seconds per rep with rest between sets", opts(req))

    assert request_count(counter) == 1
    assert Enum.count(draft.definition_json["events"], &(&1["kind"] == "rest")) == 1
  end

  test "a rest-first plan cannot stretch unrequested movement pace to fill the clock", %{
    counter: counter
  } do
    user = user_fixture()

    slow = %{
      "version" => 1,
      "name" => "Slow movement instead of recovery",
      "burpee_type" => "six_count",
      "target_duration_sec" => 1_200,
      "target_reps" => 140,
      "pacing_style" => "unbroken",
      "rationale" => "Two continuous sets with recovery between them",
      "events" => [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 8.0, "sec_per_burpee" => 8.0},
        %{"kind" => "rest", "duration_sec" => 80.0},
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 8.0, "sec_per_burpee" => 8.0}
      ]
    }

    rested =
      slow
      |> Map.put("name", "Recovery between sets")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0},
        %{"kind" => "rest", "duration_sec" => 500.0},
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5.0, "sec_per_burpee" => 5.0}
      ])

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, slow),
          else: provider_definition(conn, rested)
      end)

    assert {:ok, draft} =
             Coach.create_draft(user, "140 six-counts in 20 minutes with recovery", opts(req))

    assert request_count(counter) == 2
    assert draft.definition_json["events"] |> Enum.any?(&(&1["duration_sec"] == 500.0))
    [_first, correction] = requests(counter)
    feedback = List.last(correction.body["messages"])["content"]
    assert feedback =~ "movement pace"
    assert feedback =~ "work_sec=1120 rest_sec=80"
    assert feedback =~ "rest_budget_at_reference_pace_sec=500"
    refute feedback =~ "rest_budget_at_target_reps_sec=80"
  end

  test "a roughly eight-second Navy Seal pace does not cause a paid correction", %{
    counter: counter
  } do
    user = user_fixture()

    plan =
      definition("Navy Seal recovery")
      |> Map.put("burpee_type", "navy_seal")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 8.5, "sec_per_burpee" => 8.5},
        %{"kind" => "rest", "duration_sec" => 35.0},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 8.5, "sec_per_burpee" => 8.5}
      ])

    req = request(counter, &provider_definition(&1, plan))

    assert {:ok, _draft} = Coach.create_draft(user, "Navy Seal sets with recovery", opts(req))
    assert request_count(counter) == 1
  end

  test "a rest-first plan does not use an unrequested faster-than-reference pace", %{
    counter: counter
  } do
    user = user_fixture()

    fast =
      definition("Too fast for the default reference")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 3.0, "sec_per_burpee" => 3.0},
        %{"kind" => "rest", "duration_sec" => 90.0},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 3.0, "sec_per_burpee" => 3.0}
      ])

    corrected =
      Map.put(fast, "events", [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 4.0, "sec_per_burpee" => 4.0},
        %{"kind" => "rest", "duration_sec" => 80.0},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 4.0, "sec_per_burpee" => 4.0}
      ])

    req =
      request(counter, fn conn ->
        if request_count(counter) == 1,
          do: provider_definition(conn, fast),
          else: provider_definition(conn, corrected)
      end)

    assert {:ok, draft} = Coach.create_draft(user, "Two sets with rest between them", opts(req))
    assert request_count(counter) == 2
    assert Enum.any?(draft.definition_json["events"], &(&1["duration_sec"] == 80.0))
  end

  test "two invalid timelines leave an existing draft unchanged", %{counter: counter} do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user, %{definition: definition("Original")})
    before = raw_row(draft.id)
    invalid = Map.put(definition("Invalid"), "target_reps", 11)
    req = request(counter, &provider_definition(&1, invalid))

    assert {:error, %Error{code: :invalid_workout_definition}} =
             Coach.refine_draft(user, draft.id, "Try more reps", opts(req))

    assert request_count(counter) == 2
    assert raw_row(draft.id) == before
    assert {:ok, context} = Context.ensure_session(user, Repo.reload!(draft), "draft:#{draft.id}")
    assert {:ok, entries} = Context.entries(user, context.id)
    assert Enum.count(entries, &(&1.kind == :outcome and &1.payload["status"] == "failed")) == 2
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

  test "failed create boundaries persist nothing and only validation errors retry once", %{
    counter: counter
  } do
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
       provider_config(), :invalid_workout_definition, 2},
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
             "active_attempt" => %{"instruction" => ^instruction}
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

    assert request_count(counter) == 2
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

    first_pid = await_provider_ready(first, :first_provider_ready, barrier)
    second_pid = await_provider_ready(second, :second_provider_ready, barrier)

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

  defp shown_workout(user) do
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(user, DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(user, slot)
    {user, slot, shown}
  end

  test "Home revision waits for confirmed constraints before replacing the selection", %{
    counter: counter
  } do
    {user, slot, shown} = shown_workout(user_fixture())
    before = shown.plan.id

    extracted = %{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    extraction = request(counter, &provider_definition(&1, extracted))

    assert {:ok, prepared} =
             Coach.prepare_home_revision(user, shown, "Change this workout", opts(extraction))

    assert request_count(counter) == 1
    assert {:ok, unchanged} = Workouts.ensure_home_selection(user, slot)
    assert unchanged.plan.id == before

    plan = request(counter, &provider_definition(&1, definition("Confirmed revision")))
    assert {:ok, revised} = Coach.confirm_home_revision(user, prepared, opts(plan))
    assert request_count(counter) == 2
    assert revised.plan.name == "Confirmed revision"
    assert revised.plan.id != before
  end

  test "Home adjustment saves a timed-rest proposal within tolerance without a repair", %{
    counter: counter
  } do
    {user, slot, shown} = shown_workout(user_fixture())
    original_id = shown.plan.id
    unrelated = plan_fixture(user)

    extracted = %{
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "recovery" => "required",
      "timed_rests" => [
        %{"start_sec" => 660, "duration_sec" => 60},
        %{"start_sec" => 1_080, "duration_sec" => 30}
      ],
      "requested_pace_sec" => nil
    }

    assert {:ok, prepared} =
             Coach.prepare_home_revision(
               user,
               shown,
               "140 reps in 20 minutes, rest at 11:00 and 18:00",
               opts(request(counter, &provider_definition(&1, extracted)))
             )

    assert {:ok, unchanged} = Workouts.ensure_home_selection(user, slot)
    assert unchanged.plan.id == original_id

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    proposal = %{
      "version" => 1,
      "name" => "Timed rest adjustment",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "rationale" => "The chosen work sets and recovery fit the requested session.",
      "phase_1" => %{
        "work_rest_pairs" => [%{"work" => work.(88), "rest_after" => rest.(110.5)}],
        "last_work" => work.(22)
      },
      "rest_1" => rest.(60),
      "phase_2" => %{
        "work_rest_pairs" => [%{"work" => work.(10), "rest_after" => rest.(300.5)}],
        "last_work" => work.(2)
      },
      "rest_2" => rest.(30),
      "phase_3" => %{"work_rest_pairs" => [], "last_work" => work.(18)}
    }

    assert {:ok, revised} =
             Coach.confirm_home_revision(
               user,
               prepared,
               opts(request(counter, &provider_definition(&1, proposal)))
             )

    assert request_count(counter) == 2
    assert revised.plan.id != original_id
    assert revised.plan.target_reps == 140
    assert revised.plan.target_duration_sec == 1_201
    assert revised.plan.definition_json["target_duration_sec"] == 1_201
    assert {:ok, reloaded} = Workouts.ensure_home_selection(user, slot)
    assert reloaded.plan.id == revised.plan.id
    assert Workouts.get_plan!(user, unrelated.id).id == unrelated.id
  end

  test "failed published revision retains history through reload", %{counter: counter} do
    {user, slot, initial} = shown_workout(user_fixture())
    source = plan_fixture(user, %{burpee_type: "navy_seal"})
    {:ok, shown} = Workouts.select_home_workout(user, initial, source.id)
    before = raw_row(source.id)
    req = request(counter, &Plug.Conn.send_resp(&1, 503, "private response"))

    assert {:error, %Error{code: :provider_unavailable}} =
             Coach.revise_home_workout(user, shown, "Less rest", opts(req))

    assert Workouts.list_drafts(user) == []
    {:ok, reopened} = Workouts.ensure_home_selection(user, slot)
    {:ok, session} = Context.ensure_session(user, source, Context.home_key(reopened))
    {:ok, entries} = Context.entries(user, session.id)
    assert Enum.any?(entries, &(&1.kind == :instruction and &1.payload["text"] == "Less rest"))
    assert Enum.any?(entries, &(&1.kind == :outcome and &1.payload["status"] == "failed"))

    req =
      request(
        counter,
        &provider_definition(&1, definition("Six-count revision", "six_count", 100, 1200))
      )

    assert {:ok, revised} = Coach.revise_home_workout(user, reopened, "Use six-counts", opts(req))
    assert revised.plan.design_session_id == session.id
    assert revised.plan.id != source.id
    assert revised.plan.burpee_type == :six_count
    assert raw_row(source.id) == before
    assert request_count(counter) == 2
  end

  test "historical overflow stays stored without bloating the next provider request", %{
    counter: counter
  } do
    {user, _slot, shown} = shown_workout(user_fixture())
    {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))

    for _ <- 1..530 do
      {:ok, _} =
        Context.append(user, context.id, Ecto.UUID.generate(), :instruction, %{
          "text" => String.duplicate("x", 500)
        })
    end

    req = request(counter, &provider_definition(&1, definition("Unused")))

    assert {:ok, revised} = Coach.revise_home_workout(user, shown, "Try once", opts(req))

    assert revised.plan.name == "Unused"
    assert request_count(counter) == 1
    [recorded] = requests(counter)
    provider_body = recorded.body["messages"] |> List.last() |> Map.fetch!("content")
    refute provider_body =~ String.duplicate("x", 500)
    {:ok, entries} = Context.entries(user, context.id)
    assert length(entries) > 530
    assert List.last(entries).payload["status"] == "accepted"
  end

  test "provider exception is caught and receives a safe outcome", %{counter: counter} do
    {user, _slot, shown} = shown_workout(user_fixture())
    req = request(counter, fn _conn -> raise "private exception text" end)

    assert {:error, %Error{code: :provider_unavailable}} =
             Coach.revise_home_workout(user, shown, "Change it", opts(req))

    {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))
    {:ok, entries} = Context.entries(user, context.id)
    outcome = List.last(entries)
    assert outcome.kind == :outcome
    assert outcome.payload == %{"status" => "failed", "code" => "provider_unavailable"}
  end

  test "selection changed during HTTP creates no orphan", %{counter: counter} do
    {user, _slot, shown} = shown_workout(user_fixture())
    alternative = plan_fixture(user)

    req =
      request(counter, fn conn ->
        {:ok, _} = Workouts.select_home_workout(user, shown, alternative.id)
        provider_definition(conn, definition("Must not persist"))
      end)

    assert {:error, %Error{code: :home_selection_changed}} =
             Coach.revise_home_workout(user, shown, "Revise", opts(req))

    assert Workouts.list_drafts(user) == []
    assert request_count(counter) == 1
  end

  test "failure-log failure does not replace the provider error", %{counter: counter} do
    {user, _slot, shown} = shown_workout(user_fixture())
    {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))

    req =
      request(counter, fn conn ->
        # Simulates loss of the log store after the instruction was persisted.
        Repo.delete_all(from(e in DesignEntry, where: e.design_session_id == ^context.id))
        Repo.delete_all(from(s in BurpeeTrainer.Coach.DesignSession, where: s.id == ^context.id))
        Req.Test.transport_error(conn, :timeout)
      end)

    assert capture_log(fn ->
             assert {:error, %Error{code: :provider_timeout}} =
                      Coach.revise_home_workout(user, shown, "Try", opts(req))
           end) =~ "workout_design_failure_outcome_unavailable"

    assert Workouts.list_drafts(user) == []
    assert Repo.get(BurpeeTrainer.Coach.DesignSession, context.id) == nil
  end

  test "accepted Home revision commits content pointer and outcome together", %{counter: counter} do
    {user, slot, shown} = shown_workout(user_fixture())

    req =
      request(counter, fn conn ->
        refute Repo.in_transaction?()
        provider_definition(conn, definition("Accepted Home"))
      end)

    assert {:ok, changed} = Coach.revise_home_workout(user, shown, "Change", opts(req))
    assert changed.home_revision > shown.home_revision
    assert {:ok, reopened} = Workouts.ensure_home_selection(user, slot)
    assert reopened == changed
    assert {:ok, entries} = Context.entries(user, changed.plan.design_session_id)
    outcome = List.last(entries)

    assert outcome.payload == %{
             "status" => "accepted",
             "workout_plan_id" => changed.plan.id,
             "content_hash" => changed.plan.content_hash,
             "updated_at" => DateTime.to_iso8601(changed.plan.updated_at)
           }
  end

  test "accepted log failure rolls back draft and Home pointer", %{counter: counter} do
    {user, slot, shown} = shown_workout(user_fixture())

    Repo.query!("""
    CREATE TEMP TRIGGER reject_design_accept BEFORE INSERT ON workout_design_entries
    WHEN NEW.kind = 'outcome' AND json_extract(NEW.payload, '$.status') = 'accepted'
    BEGIN SELECT RAISE(ABORT, 'test accepted failure'); END
    """)

    try do
      req = request(counter, &provider_definition(&1, definition("Rolled back")))
      assert {:error, %Error{}} = Coach.revise_home_workout(user, shown, "Change", opts(req))
      assert Workouts.list_drafts(user) == []
      assert {:ok, ^shown} = Workouts.ensure_home_selection(user, slot)
      {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))
      {:ok, entries} = Context.entries(user, context.id)
      assert List.last(entries).payload["status"] == "failed"
      refute Enum.any?(entries, &(&1.payload["status"] == "accepted"))
    after
      Repo.query!("DROP TRIGGER reject_design_accept")
    end
  end

  test "Home pointer failure rolls back draft and accepted outcome", %{counter: counter} do
    {user, slot, shown} = shown_workout(user_fixture())

    Repo.query!("""
    CREATE TEMP TRIGGER reject_home_pointer BEFORE UPDATE OF home_workout_plan_id ON coach_recommendations
    BEGIN SELECT RAISE(ABORT, 'test accepted failure'); END
    """)

    try do
      req = request(counter, &provider_definition(&1, definition("Rolled back")))
      assert {:error, %Error{}} = Coach.revise_home_workout(user, shown, "Change", opts(req))
      assert Workouts.list_drafts(user) == []
      assert {:ok, ^shown} = Workouts.ensure_home_selection(user, slot)
      {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))
      {:ok, entries} = Context.entries(user, context.id)
      assert List.last(entries).payload["status"] == "failed"
      refute Enum.any?(entries, &(&1.payload["status"] == "accepted"))
    after
      Repo.query!("DROP TRIGGER reject_home_pointer")
    end
  end

  test "authoring refuses persistence transactions before HTTP", %{counter: counter} do
    user = user_fixture()
    req = request(counter, &provider_definition(&1, definition("Unused")))

    assert capture_log(fn ->
             assert {:ok, {:error, %Error{code: :authoring_transaction_forbidden}}} =
                      Repo.transaction(fn -> Coach.create_draft(user, "Try", opts(req)) end)
           end) =~ "workout_draft_create_failed error_code=authoring_transaction_forbidden"

    assert Workouts.list_drafts(user) == []

    assert request_count(counter) == 0
  end

  # Independent context writes may contend before either request reaches its provider barrier.
  defp await_provider_ready(%Task{pid: pid, ref: ref}, ready_tag, barrier) do
    receive do
      {^ready_tag, ^pid, ^barrier} ->
        pid

      {^ref, result} ->
        flunk("refinement returned before provider readiness: #{inspect(result)}")

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("refinement exited before provider readiness: #{inspect(reason)}")
    after
      10_000 -> flunk("refinement did not reach provider readiness within 10 seconds")
    end
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
