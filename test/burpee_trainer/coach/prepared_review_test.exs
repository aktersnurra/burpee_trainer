defmodule BurpeeTrainer.Coach.PreparedReviewTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, Repo}
  alias BurpeeTrainer.Coach.WorkoutRequest
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

  test "preparation saves no plan, approval is owner-bound, untampered and idempotent", %{
    user: user
  } do
    parent = self()

    definition = %{
      "version" => 1,
      "name" => "Prepared plan",
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "rationale" => "Ten steady reps.",
      "events" => [%{"kind" => "work", "reps" => 10, "sec_per_rep" => 12, "sec_per_burpee" => 12}]
    }

    provider(parent, definition)
    {:ok, request} = request([])
    before = Repo.aggregate(WorkoutPlan, :count)

    assert {:ok, old} =
             Coach.prepare_plan(user, "10 reps in 2 minutes", request,
               workspace_key: "owned-review"
             )

    assert_receive :provider_call

    assert {:ok, prepared} =
             Coach.prepare_plan(user, "10 reps in 2 minutes", request,
               workspace_key: "owned-review"
             )

    assert_receive :provider_call
    assert {:error, _} = Coach.approve_plan(user, old)
    assert Repo.aggregate(WorkoutPlan, :count) == before
    assert {:error, _} = Coach.approve_plan(user_fixture(), prepared)
    assert {:error, _} = Coach.approve_plan(user, Map.delete(prepared, :definition))
    assert {:error, _} = Coach.approve_plan(user, put_in(prepared.definition["name"], "Tampered"))
    assert {:ok, saved} = Coach.approve_plan(user, prepared)
    assert saved.state == :published
    assert Enum.any?(BurpeeTrainer.Workouts.list_library(user), &(&1.id == saved.id))
    assert {:ok, replay} = Coach.approve_plan(user, prepared)
    assert saved.id == replay.id
    assert replay.state == :published

    assert :ok =
             BurpeeTrainer.Coach.Memory.record_finalized_workout(
               user.id,
               saved.id,
               saved.design_session_id
             )

    assert [%{workout_reason: %{"accepted_instructions" => ["10 reps in 2 minutes"]}}] =
             BurpeeTrainer.Coach.Memory.global_context(user).workout_memories

    assert Repo.aggregate(WorkoutPlan, :count) == before + 1

    assert_raise Exqlite.Error, ~r/workout_plans_immutable_content_check/, fn ->
      Repo.update!(Ecto.Changeset.change(saved, content_hash: "changed"))
    end

    assert {:ok, %{id: id}} = Coach.approve_plan(user, prepared)
    assert id == saved.id
    refute_received :provider_call
  end

  test "global 25-second recovery is feasible for the reported minute-block edit", %{user: user} do
    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    phase = fn reps ->
      %{
        "work_rest_pairs" =>
          Enum.map(Enum.drop(reps, -1), &%{"work" => work.(&1), "rest_after" => rest.(25)}),
        "last_work" => work.(List.last(reps))
      }
    end

    proposed = %{
      "version" => 1,
      "name" => "Minute recovery blocks",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1200,
      "pacing_style" => "unbroken",
      "rationale" =>
        "Ordinary pauses are 25 seconds across all phases, excluding the fixed60 and40 seconds. Total20 minutes.",
      "phase_1" => phase.(List.duplicate(8, 5) ++ List.duplicate(7, 6)),
      "rest_1" => rest.(60),
      "phase_2" => phase.(List.duplicate(8, 5) ++ [7]),
      "rest_2" => rest.(40),
      "phase_3" => phase.([6, 5])
    }

    provider(self(), proposed)

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 140,
        "target_duration_sec" => 1200,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "requested_pace_sec" => 5,
        "timed_rests" => [
          %{"start_sec" => 660, "duration_sec" => 60},
          %{"start_sec" => 1080, "duration_sec" => 40}
        ]
      })

    before = Repo.aggregate(WorkoutPlan, :count)

    assert {:ok, prepared} =
             Coach.prepare_plan(
               user,
               "Make the rests more even with roughly minute-long blocks; keep fixed pauses at11 and18 minutes.",
               request
             )

    assert_receive :provider_call
    refute_received :provider_call
    refute prepared.alternative?
    assert prepared.definition["target_duration_sec"] == 1200
    assert length(prepared.request.set_reps) == 19
    {:ok, definition} = BurpeeTrainer.PlanCompiler.WorkoutDefinition.new(prepared.definition)
    pauses = WorkoutRequest.rest_timeline(definition.events)
    assert {660_000_000, 60_000_000} in pauses
    assert {1080_000_000, 40_000_000} in pauses
    assert Enum.count(pauses, &(elem(&1, 1) == 25_000_000)) == 16
    assert :ok = WorkoutRequest.validate_definition(request, definition)
    assert Repo.aggregate(WorkoutPlan, :count) == before
  end

  test "locally negative movement budget never invokes the provider", %{user: user} do
    provider(self(), %{})
    {:ok, request} = request([])
    request = %{request | requested_pace_sec: 15}

    assert {:error, %{code: :invalid_workout_definition}} =
             Coach.prepare_plan(user, "10 reps in 2 minutes", request)

    refute_received :provider_call
  end

  test "bounded failed anchor yields a validated alternative requiring explicit acceptance", %{
    user: user
  } do
    parent = self()

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    phased = %{
      "version" => 1,
      "name" => "Alternate anchor",
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 110,
      "pacing_style" => "unbroken",
      "rationale" => "An earlier total pause.",
      "phase_1" => %{"work_rest_pairs" => [], "last_work" => work.(6)},
      "rest_1" => %{"kind" => "rest", "duration_sec" => 60},
      "phase_2" => %{"work_rest_pairs" => [], "last_work" => work.(4)}
    }

    provider(parent, phased)

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 110,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "timed_rests" => [%{"start_sec" => 45, "duration_sec" => 60}],
        "requested_pace_sec" => 5,
        "set_reps" => [6, 4]
      })

    assert {:ok, prepared} = Coach.prepare_plan(user, "10 reps, active pace 5s per rep", request)
    assert prepared.alternative?
    assert prepared.request.timed_rests == [%{start_sec: 30, duration_sec: 60}]
    assert_receive :provider_call
    assert_receive :provider_call
    refute_received :provider_call

    assert {:error, %{code: :alternative_confirmation_required}} =
             Coach.approve_plan(user, prepared)

    assert {:ok, _} = Coach.approve_plan(user, prepared, accept_alternative: true)
    refute_received :provider_call
  end

  test "140 reps and twenty ordered sets keep total pauses inside the shared recovery pool", %{
    user: user
  } do
    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    phase = fn reps, pauses ->
      pairs =
        Enum.zip(Enum.drop(reps, -1), pauses)
        |> Enum.map(fn {reps, pause} ->
          %{"work" => work.(reps), "rest_after" => rest.(pause)}
        end)

      %{"work_rest_pairs" => pairs, "last_work" => work.(List.last(reps))}
    end

    sets = List.duplicate(8, 5) ++ List.duplicate(7, 5) ++ List.flatten(List.duplicate([7, 6], 5))

    proposal = %{
      "version" => 1,
      "name" => "Shared recovery pool",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1200,
      "pacing_style" => "unbroken",
      "rationale" => "Reallocated ordinary and future recovery, with exact total pauses.",
      "phase_1" => phase.(Enum.take(sets, 10), List.duplicate(32, 8) ++ [29]),
      "rest_1" => rest.(60),
      "phase_2" => phase.(Enum.slice(sets, 10, 7), List.duplicate(20, 6)),
      "rest_2" => rest.(30),
      "phase_3" => phase.(Enum.drop(sets, 17), [2, 3])
    }

    provider(self(), proposal)

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 140,
        "target_duration_sec" => 1200,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "timed_rests" => [
          %{"start_sec" => 660, "duration_sec" => 60},
          %{"start_sec" => 1080, "duration_sec" => 30}
        ],
        "requested_pace_sec" => 5,
        "set_reps" => sets
      })

    assert {:ok, prepared} =
             Coach.prepare_plan(user, "140 reps in 20:00, active pace 5s per rep", request)

    assert_receive :provider_call
    refute_received :provider_call
    refute prepared.alternative?
    assert prepared.definition["target_duration_sec"] == 1200
    {:ok, definition} = BurpeeTrainer.PlanCompiler.WorkoutDefinition.new(prepared.definition)
    pauses = WorkoutRequest.rest_timeline(definition.events)
    assert {660_000_000, 60_000_000} in pauses
    assert {1_070_000_000, 30_000_000} in pauses
    assert Enum.sum(Enum.map(pauses, &elem(&1, 1))) == 500_000_000
    assert :ok = WorkoutRequest.validate_definition(request, definition)
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

  defp provider(parent, definition) do
    Req.default_options(
      adapter: fn request ->
        send(parent, :provider_call)

        {request,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "choices" => [%{"message" => %{"content" => Jason.encode!(definition)}}]
             })
         }}
      end
    )
  end
end
