defmodule BurpeeTrainer.Coach.PreparedReviewTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.{Coach, LayoutFixtures, Repo, ReqStub, Workouts}
  alias BurpeeTrainer.Coach.{Policy, WorkoutRequest}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  setup do
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)

    on_exit(fn ->
      Req.default_options(previous_req)
      Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "test",
      model: "test"
    )

    %{user: user_fixture()}
  end

  test "preparation saves no plan; approval remains owner-bound, untampered and idempotent", %{
    user: user
  } do
    provider(
      self(),
      List.duplicate(LayoutFixtures.layout([[{10, 12.0, 12.0}]], "Prepared plan"), 2)
    )

    selected_plan = plan_fixture(user)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, selection} = Workouts.ensure_home_selection(Scope.for_user(user), slot)

    assert {:ok, selected} =
             Workouts.select_home_workout(Scope.for_user(user), selection, selected_plan.id)

    selected_before = {:ok, selected}

    {:ok, request} = request([])
    before = Repo.aggregate(WorkoutPlan, :count)

    assert {:ok, old} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request,
               workspace_key: "owned-review"
             )

    assert_receive :provider_call
    refute Map.has_key?(old, :alternative?)

    assert {:ok, prepared} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request,
               workspace_key: "owned-review"
             )

    assert_receive :provider_call
    assert old.approval_key != prepared.approval_key
    assert Repo.aggregate(WorkoutPlan, :count) == before
    assert {:error, _} = Coach.approve_plan(scope_fixture(), prepared)

    assert {:error, _} =
             Coach.approve_plan(Scope.for_user(user), Map.delete(prepared, :definition))

    assert {:ok, saved} = Coach.approve_plan(Scope.for_user(user), prepared)

    assert {:error, _} =
             Coach.approve_plan(
               Scope.for_user(user),
               put_in(prepared.definition["name"], "Tampered")
             )

    assert saved.approval_key == prepared.approval_key
    assert saved.state == :published
    assert saved.id != selected.plan.id
    assert Workouts.ensure_home_selection(Scope.for_user(user), slot) == selected_before

    assert Enum.any?(
             BurpeeTrainer.Workouts.list_library(Scope.for_user(user)),
             &(&1.id == saved.id)
           )

    assert {:ok, replay} = Coach.approve_plan(Scope.for_user(user), prepared)
    assert saved.id == replay.id
    assert Workouts.ensure_home_selection(Scope.for_user(user), slot) == selected_before
    assert Repo.aggregate(WorkoutPlan, :count) == before + 1
    refute_received :provider_call
  end

  test "fixed pauses at minute 11 and 18 fit exactly in one provider call", %{user: user} do
    eight = {8, 5.0, 5.0}
    six = {6, 5.0, 5.0}

    layout =
      LayoutFixtures.layout([List.duplicate(eight, 10), List.duplicate(eight, 6), [six, six]])

    provider(self(), [layout])

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 140,
        "target_duration_sec" => 1200,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "requested_pace_sec" => 5.0,
        "timed_rests" => [
          %{"start_sec" => 660, "duration_sec" => 60},
          %{"start_sec" => 1080, "duration_sec" => 40}
        ]
      })

    assert {:ok, prepared} = Coach.prepare_plan(Scope.for_user(user), "minute blocks", request)
    assert_receive :provider_call
    refute_received :provider_call
    assert prepared.definition["target_duration_sec"] == 1200
    {:ok, definition} = BurpeeTrainer.PlanCompiler.WorkoutDefinition.new(prepared.definition)
    pauses = WorkoutRequest.rest_timeline(definition.events)
    assert {660_000_000, 60_000_000} in pauses
    assert {1_080_000_000, 40_000_000} in pauses
    assert :ok = WorkoutRequest.validate_definition(request, definition)
  end

  test "one infeasible layout is corrected once and then prepared", %{user: user} do
    bad = LayoutFixtures.layout([[{10, 15.0, 15.0}]], "Too slow")
    good = LayoutFixtures.layout([[{10, 12.0, 12.0}]], "Corrected")
    provider(self(), [bad, good])
    {:ok, request} = request([])

    assert {:ok, prepared} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request)

    assert prepared.definition["name"] == "Corrected"
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call
  end

  test "schema and confirmed-rep validation failures are corrected without changing constraints",
       %{user: user} do
    good = LayoutFixtures.layout([[{10, 12.0, 12.0}]], "Correct")
    schema_bad = %{"name" => nil, "rationale" => "bad", "phases" => good["phases"]}
    provider(self(), [schema_bad, good])
    {:ok, request} = request([])

    assert {:ok, prepared} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request,
               workspace_key: "schema-correction"
             )

    assert prepared.definition["target_reps"] == 10
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call

    wrong_reps = LayoutFixtures.layout([[{9, 12.0, 12.0}]], "Wrong reps")
    provider(self(), [wrong_reps, good])

    assert {:ok, prepared} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request,
               workspace_key: "rep-correction"
             )

    assert prepared.definition["target_reps"] == 10
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call
  end

  test "invalid corrected layout stops after two calls without publishing a plan", %{user: user} do
    provider(self(), [%{}, %{}])
    {:ok, request} = request([])
    before = Repo.aggregate(WorkoutPlan, :count)

    assert {:error, %{code: :infeasible_workout_definition, context: %{diagnostic: diagnostic}}} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request)

    assert is_binary(diagnostic)
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call
    assert Repo.aggregate(WorkoutPlan, :count) == before
  end

  test "compiler-invalid layout is corrected once", %{user: user} do
    compiler_bad = LayoutFixtures.layout([[{10, 12.0, 11.0}]], "Uneven unbroken")
    good = LayoutFixtures.layout([[{10, 12.0, 12.0}]], "Compiler corrected")
    provider(self(), [compiler_bad, good])

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 120,
        "pacing_style" => "unbroken",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })

    assert {:ok, prepared} =
             Coach.prepare_plan(Scope.for_user(user), "unbroken ten reps", request)

    assert prepared.definition["name"] == "Compiler corrected"
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call
  end

  test "default movement pace rejection uses the confirmed request and is corrected only once", %{
    user: user
  } do
    slow = LayoutFixtures.layout([[{5, 11.0, 11.0}, {5, 11.0, 11.0}]], "Slow")
    provider(self(), [slow, slow])

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 120,
        "pacing_style" => "even",
        "recovery" => "required",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })

    assert {:error, %{code: :invalid_workout_definition, context: %{diagnostic: diagnostic}}} =
             Coach.prepare_plan(Scope.for_user(user), "ten reps please", request)

    assert diagnostic =~ "movement_pace_outside_default"
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call
  end

  test "edit-source correction forwards instruction and immutable source reference on both calls",
       %{user: user} do
    original = plan_fixture(user, %{request_text: "original source instruction"})
    original_definition = original.definition_json
    original_hash = original.content_hash
    instruction = "Keep the source character; my free note says settle into measured recovery."
    bad = LayoutFixtures.layout([[{10, 15.0, 15.0}]], "Infeasible edit")
    good = LayoutFixtures.layout([[{10, 12.0, 12.0}]], "Corrected edit")
    provider(self(), [bad, good])
    {:ok, request} = request([])

    assert {:ok, prepared} =
             Coach.prepare_plan(Scope.for_user(user), instruction, request,
               workspace_key: "edit-source-correction",
               edit_source: %{id: original.id, content_hash: original_hash}
             )

    assert prepared.source == %{"plan_id" => original.id, "content_hash" => original_hash}
    assert_receive :provider_call
    assert_receive {:provider_request, first}
    assert_receive :provider_call
    assert_receive {:provider_request, second}
    refute_received :provider_call

    for envelope <- [first, second] do
      messages = envelope["messages"]

      design =
        Enum.find_value(messages, fn message ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => "workout_design"} = payload} -> payload
            _ -> nil
          end
        end)

      assert design["active_attempt"]["instruction"] == instruction

      source =
        Enum.find_value(messages, fn message ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => "edit_workout_source"} = payload} -> payload
            _ -> nil
          end
        end)

      assert source["definition"] == original_definition

      confirmed =
        Enum.find_value(messages, fn message ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => "confirmed_workout_request"} = payload} -> payload
            _ -> nil
          end
        end)

      assert confirmed["request"] == WorkoutRequest.to_map(request)
    end

    assert %{definition_json: ^original_definition, content_hash: ^original_hash} =
             Repo.get!(WorkoutPlan, original.id)
  end

  test "locally negative movement budget never invokes the provider", %{user: user} do
    provider(self(), [%{}])
    {:ok, request} = request([])
    request = %{request | requested_pace_sec: 15}

    assert {:error, %{code: :invalid_workout_definition}} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request)

    refute_received :provider_call
  end

  defp request(rests) do
    WorkoutRequest.new(%{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => rests,
      "requested_pace_sec" => nil
    })
  end

  defp provider(parent, responses) do
    responses = start_supervised!({Agent, fn -> responses end}, id: make_ref())

    ReqStub.default(fn request ->
      send(parent, :provider_call)
      send(parent, {:provider_request, Jason.decode!(request.body)})

      response =
        Agent.get_and_update(responses, fn
          [response | remaining] -> {response, remaining}
          [] -> {%{}, []}
        end)

      {request,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "choices" => [%{"message" => %{"content" => Jason.encode!(response)}}]
           })
       }}
    end)
  end
end
