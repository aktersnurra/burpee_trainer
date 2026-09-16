defmodule BurpeeTrainer.Coach.HomeBootstrapTest do
  use BurpeeTrainer.DataCase, async: false

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Coach.{Context, DesignSession, Policy}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error, WorkoutPlan, WorkoutSession}

  setup do
    counter = start_supervised!({Agent, fn -> 0 end})
    %{counter: counter}
  end

  test "interpretation keeps minute recovery blocks separate from active work and pace" do
    user = user_fixture()
    parent = self()

    extracted = %{
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
    }

    req =
      Req.new(
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          [system | _] = Jason.decode!(body)["messages"]
          send(parent, {:extraction_prompt, system["content"]})
          Plug.Conn.send_resp(conn, 200, provider_body(extracted))
        end
      )

    text =
      "try to make the rests more even except the 60s and 40s rests at min 11 and 18. try to base each set to be roughly 1 min long and then use the shave off to save up to the additional rests"

    assert {:ok, prepared} =
             Coach.prepare_home_bootstrap(user, required_slot(user), text, opts(req))

    assert prepared.text == text
    assert_receive {:extraction_prompt, prompt}
    assert prompt =~ "work plus ordinary recovery"
    assert prompt =~ "not sixty seconds of active work"
    assert prompt =~ "inherit its active movement pace"

    assert prompt =~
             "Keep approximate block lengths and even-rest preferences in the active instruction"

    assert prepared.request.timed_rests |> Enum.map(& &1.start_sec) == [660, 1080]
    assert Repo.aggregate(from(p in WorkoutPlan, where: p.user_id == ^user.id), :count) == 0
  end

  test "blank and over-limit prompts do no authoring work", %{counter: counter} do
    user = user_fixture()
    slot = required_slot(user)
    req = request(counter, definition("Unused"))

    byte_over_limit = String.duplicate("👍🏽", 499) <> "👨‍👩‍👧‍👦"
    assert String.length(byte_over_limit) <= 500
    assert byte_size(byte_over_limit) > 4_000

    for prompt <- ["", "  \n\t ", String.duplicate("a", 501), byte_over_limit] do
      assert {:error, %Error{code: :invalid_workout_definition}} =
               Coach.bootstrap_home_draft(user, slot, prompt, opts(req))
    end

    assert request_count(counter) == 0
    assert Repo.aggregate(from(p in WorkoutPlan, where: p.user_id == ^user.id), :count) == 0

    assert Repo.aggregate(from(r in CoachRecommendation, where: r.user_id == ^user.id), :count) ==
             0

    assert Repo.aggregate(from(s in WorkoutSession, where: s.user_id == ^user.id), :count) == 0
    assert Repo.aggregate(from(s in DesignSession, where: s.user_id == ^user.id), :count) == 0
  end

  test "preparing first-use constraints does not create or select a workout", %{counter: counter} do
    user = user_fixture()
    slot = required_slot(user)

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

    req = request(counter, extracted)

    assert {:ok, prepared} =
             Coach.prepare_home_bootstrap(
               user,
               slot,
               "140 reps in 20 minutes with rests",
               opts(req)
             )

    assert prepared.request.target_reps == 140
    assert prepared.request.timed_rests |> Enum.map(& &1.start_sec) == [660, 1_080]
    assert request_count(counter) == 1
    assert Repo.aggregate(from(p in WorkoutPlan, where: p.user_id == ^user.id), :count) == 0

    assert Repo.aggregate(from(r in CoachRecommendation, where: r.user_id == ^user.id), :count) ==
             0
  end

  test "confirmed first-use request rejects a plan matching its own wrong targets", %{
    counter: counter
  } do
    user = user_fixture()
    slot = required_slot(user)

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
             Coach.prepare_home_bootstrap(
               user,
               slot,
               "140 reps in 20 minutes",
               opts(request(counter, extracted))
             )

    wrong =
      definition("Wrong echoed targets")
      |> Map.put("target_reps", 280)
      |> Map.put("target_duration_sec", 1_260)
      |> Map.put("pacing_style", "unbroken")
      |> Map.put("events", [
        %{"kind" => "work", "reps" => 280, "sec_per_rep" => 4.5, "sec_per_burpee" => 4.5}
      ])

    assert {:error, %Error{code: :invalid_workout_definition}} =
             Coach.confirm_home_bootstrap(user, prepared, opts(request(counter, wrong)))

    assert request_count(counter) == 3
    assert Repo.aggregate(from(p in WorkoutPlan, where: p.user_id == ^user.id), :count) == 0
  end

  test "a mistimed rest gets one bounded repair against confirmed elapsed anchors", %{
    counter: counter
  } do
    user = user_fixture()
    slot = required_slot(user)

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
             Coach.prepare_home_bootstrap(
               user,
               slot,
               "140 reps with rests at 11 and 18 minutes",
               opts(request(counter, extracted))
             )

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    valid = %{
      "version" => 1,
      "name" => "Anchored workout",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "rationale" => "Explicit between-set recovery at both requested times.",
      "phase_1" => %{
        "work_rest_pairs" => [%{"work" => work.(88), "rest_after" => rest.(110)}],
        "last_work" => work.(22)
      },
      "rest_1" => rest.(60),
      "phase_2" => %{
        "work_rest_pairs" => [%{"work" => work.(10), "rest_after" => rest.(300)}],
        "last_work" => work.(2)
      },
      "rest_2" => rest.(30),
      "phase_3" => %{"work_rest_pairs" => [], "last_work" => work.(18)}
    }

    mistimed =
      valid
      |> put_in(["phase_1", "work_rest_pairs", Access.at(0), "rest_after", "duration_sec"], 121)
      |> put_in(["phase_2", "work_rest_pairs", Access.at(0), "rest_after", "duration_sec"], 289)

    test_pid = self()

    planning_req =
      Req.new(
        plug: fn conn ->
          ordinal = Agent.get_and_update(counter, fn count -> {count, count + 1} end)
          send(test_pid, {:provider_request, ordinal, conn.body_params})

          Plug.Conn.send_resp(
            conn,
            200,
            provider_body(if(ordinal == 1, do: mistimed, else: valid))
          )
        end
      )

    assert {:ok, selected} = Coach.confirm_home_bootstrap(user, prepared, opts(planning_req))
    assert selected.plan.target_reps == 140
    assert selected.plan.target_duration_sec == 1_200
    assert request_count(counter) == 3
    assert_receive {:provider_request, 2, correction}
    assert List.last(correction["messages"])["content"] =~ "start_sec=660"

    assert List.last(correction["messages"])["content"] =~
             "phase_seconds=[671, 349, 90] expected=[660, 360, 90]"
  end

  test "confirmed timed rests are flattened from the provider's mandatory phased response", %{
    counter: counter
  } do
    user = user_fixture()
    slot = required_slot(user)

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
             Coach.prepare_home_bootstrap(
               user,
               slot,
               "140 reps, recovery at 11 and 18 minutes",
               opts(request(counter, extracted))
             )

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    phased = %{
      "version" => 1,
      "name" => "Confirmed phased workout",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "rationale" => "Explicit rests between all sets.",
      "phase_1" => %{
        "work_rest_pairs" => [%{"work" => work.(88), "rest_after" => rest.(110)}],
        "last_work" => work.(22)
      },
      "rest_1" => rest.(60),
      "phase_2" => %{
        "work_rest_pairs" => [%{"work" => work.(10), "rest_after" => rest.(300)}],
        "last_work" => work.(2)
      },
      "rest_2" => rest.(30),
      "phase_3" => %{"work_rest_pairs" => [], "last_work" => work.(18)}
    }

    test_pid = self()

    planning_req =
      Req.new(
        plug: fn conn ->
          Agent.update(counter, &(&1 + 1))
          send(test_pid, {:phased_planning_request, conn.body_params})
          Plug.Conn.send_resp(conn, 200, provider_body(phased))
        end
      )

    assert {:ok, selected} = Coach.confirm_home_bootstrap(user, prepared, opts(planning_req))
    assert_receive {:phased_planning_request, body}
    assert body["response_format"]["json_schema"]["name"] == "phased_workout_definition"
    assert Enum.any?(body["messages"], &String.contains?(&1["content"], "phase_1"))
    assert Enum.any?(body["messages"], &String.contains?(&1["content"], "660"))

    assert selected.plan.target_reps == 140
    assert selected.plan.target_duration_sec == 1_200
    assert Enum.count(selected.plan.definition_json["events"], &(&1["kind"] == "rest")) == 4
    assert request_count(counter) == 2
  end

  test "within tolerance stores the actual integer duration and preserves nominal request", %{
    counter: counter
  } do
    user = user_fixture()
    slot = required_slot(user)

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
             Coach.prepare_home_bootstrap(
               user,
               slot,
               "140 reps with timed rests",
               opts(request(counter, extracted))
             )

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    rest = fn seconds -> %{"kind" => "rest", "duration_sec" => seconds} end

    proposal = %{
      "version" => 1,
      "name" => "Nearly exact workout",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1_200,
      "pacing_style" => "unbroken",
      "rationale" => "The model chose flexible rests and exact reps.",
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

    assert {:ok, selected} =
             Coach.confirm_home_bootstrap(user, prepared, opts(request(counter, proposal)))

    assert selected.plan.target_reps == 140
    assert selected.plan.target_duration_sec == 1_201
    assert selected.plan.definition_json["target_duration_sec"] == 1_201
    assert request_count(counter) == 2
  end

  test "stale confirmed first-use slot is rejected without a planning call", %{counter: counter} do
    user = user_fixture()
    slot = required_slot(user)

    extracted = %{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    assert {:ok, prepared} =
             Coach.prepare_home_bootstrap(
               user,
               slot,
               "Build a workout",
               opts(request(counter, extracted))
             )

    stale_slot = %{slot | slot_date: Date.add(slot.slot_date, -1)}
    stale = put_in(prepared, [:scope, :slot], stale_slot)
    planning_req = request(counter, definition("Should not be called"))

    assert {:error, %Error{code: :design_workspace_changed}} =
             Coach.confirm_home_bootstrap(user, stale, opts(planning_req))

    assert request_count(counter) == 1
  end

  test "one verified draft is selected atomically and retry retains source-nil context", %{
    counter: counter
  } do
    user = user_fixture()
    slot = required_slot(user)
    req = request(counter, definition("Bootstrap"))

    assert {:ok, selected} =
             Coach.bootstrap_home_draft(user, slot, "Build my first workout", opts(req))

    assert selected.plan.state == :draft
    assert selected.plan.name == "Bootstrap"
    assert request_count(counter) == 1
    assert {:ok, ^selected} = Workouts.ensure_home_selection(user, slot)

    {:ok, context} = Context.ensure_session(user, nil, "home-bootstrap:" <> slot.slot_key)
    assert selected.plan.design_session_id == context.id
    assert {:ok, entries} = Context.entries(user, context.id)
    assert Enum.any?(entries, &(&1.kind == :outcome and &1.payload["status"] == "accepted"))
  end

  test "provider, compiler, and context failures preserve the source-nil retry workspace", %{
    counter: counter
  } do
    user = user_fixture()
    slot = required_slot(user)
    unavailable = Req.new(plug: &Plug.Conn.send_resp(&1, 503, "unavailable"))

    assert {:error, %Error{code: :provider_unavailable}} =
             Coach.bootstrap_home_draft(user, slot, "Try again", opts(unavailable))

    {:ok, context} = Context.ensure_session(user, nil, "home-bootstrap:" <> slot.slot_key)
    assert {:ok, entries} = Context.entries(user, context.id)
    assert List.last(entries).payload == %{"status" => "failed", "code" => "provider_unavailable"}

    invalid = request(counter, %{"version" => 1})

    assert {:error, %Error{code: :invalid_workout_definition}} =
             Coach.bootstrap_home_draft(user, slot, "Try again", opts(invalid))

    assert {:error, %Error{code: :design_workspace_changed}} =
             Coach.bootstrap_home_draft(
               user,
               %{slot | slot_key: String.duplicate("x", 201)},
               "No context",
               opts(invalid)
             )

    recovered = request(counter, definition("Recovered"))

    assert {:ok, selected} =
             Coach.bootstrap_home_draft(user, slot, "Try again", opts(recovered))

    assert selected.plan.design_session_id == context.id
    assert request_count(counter) == 3
  end

  test "each provider-ready first-use conflict rolls back the generated draft", %{
    sandbox_owner: sandbox_owner
  } do
    for {label, expected_code, compete} <- bootstrap_conflicts() do
      user = user_fixture()
      slot = required_slot(user)
      barrier = make_ref()

      submitted_slot =
        case label do
          "changed submitted state" -> %{slot | home_state: :unavailable}
          "changed submitted slot" -> %{slot | slot_date: Date.add(slot.slot_date, -1)}
          _ -> slot
        end

      task =
        start_shared_bootstrap_task(
          self(),
          barrier,
          user,
          submitted_slot,
          definition("Must roll back")
        )

      provider_pid = await_shared_provider_ready(task, sandbox_owner, barrier)
      compete.(user, slot)
      competing_rows = bootstrap_rows(user)
      send(provider_pid, {:respond, barrier})

      assert {:error, %Error{code: ^expected_code}} = Task.await(task, 10_000), label
      assert bootstrap_rows(user) == competing_rows, label
    end
  end

  test "bootstrap alternatives are read-only and plan pin is atomic" do
    user = user_fixture()
    slot = required_slot(user)
    before = bootstrap_rows(user)

    filters = %{
      types: MapSet.new([:six_count, :navy_seal]),
      levels: MapSet.new(BurpeeTrainer.Levels.all_levels())
    }

    alternatives = Workouts.bootstrap_alternatives(user, slot, filters, :workouts)
    assert alternatives != []

    assert Enum.all?(
             alternatives,
             &(BurpeeTrainer.Coach.Catalog.plan_level(&1) in BurpeeTrainer.Levels.all_levels())
           )

    assert BurpeeTrainer.Coach.Catalog.plan_level(hd(alternatives)) == :level_1a

    assert Workouts.bootstrap_alternatives(
             user,
             slot,
             %{filters | types: MapSet.new([:impossible])},
             :videos
           ) == []

    assert bootstrap_rows(user) == before

    built_in = Repo.one!(from(p in WorkoutPlan, where: is_nil(p.user_id), limit: 1))
    assert {:ok, selected} = Workouts.select_bootstrap_home_workout(user, slot, built_in.id)
    assert selected.plan.id == built_in.id
    assert {:ok, ^selected} = Workouts.ensure_home_selection(user, slot)

    assert Repo.aggregate(from(r in CoachRecommendation, where: r.user_id == ^user.id), :count) ==
             1
  end

  test "bootstrap video replay is before eligibility and source mismatch is rejected" do
    user = user_fixture()
    slot = required_slot(user)
    video = video_fixture()
    replacement = video_fixture()
    token = Ecto.UUID.generate()

    assert {:ok, first} = Workouts.start_bootstrap_home_video(user, slot, video.id, token)
    assert {:ok, replay} = Workouts.start_bootstrap_home_video(user, slot, video.id, token)
    assert replay.id == first.id

    assert {:error, %Error{code: :start_token_source_mismatch}} =
             Workouts.start_bootstrap_home_video(user, slot, replacement.id, token)

    changed_video =
      video
      |> BurpeeTrainer.Workouts.WorkoutVideo.changeset(%{name: video.name <> " revised"})
      |> Repo.update!()

    assert {:error, %Error{code: :start_token_source_mismatch}} =
             Workouts.start_bootstrap_home_video(user, slot, changed_video.id, token)

    assert Repo.aggregate(from(s in WorkoutSession, where: s.user_id == ^user.id), :count) == 1

    assert Repo.aggregate(from(r in CoachRecommendation, where: r.user_id == ^user.id), :count) ==
             1
  end

  test "two committed bootstrap writers leave one accepted result and no orphan", %{
    sandbox_owner: owner
  } do
    Ecto.Adapters.SQL.Sandbox.stop_owner(owner)

    state =
      outside_sandbox(fn ->
        user = user_fixture()
        {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
        %{user: user, user_id: user.id, slot: slot}
      end)

    on_exit(fn -> cleanup_committed_user(state.user_id) end)

    barrier = make_ref()
    first = start_bootstrap_task(self(), :first_ready, barrier, state, definition("First"))
    second = start_bootstrap_task(self(), :second_ready, barrier, state, definition("Second"))
    first_pid = await_provider_ready(first, :first_ready, barrier)
    second_pid = await_provider_ready(second, :second_ready, barrier)
    send(first_pid, {:respond, barrier})
    first_result = Task.await(first, 10_000)
    send(second_pid, {:respond, barrier})
    second_result = Task.await(second, 10_000)

    assert Enum.count([first_result, second_result], &match?({:ok, _}, &1)) == 1

    outside_sandbox(fn ->
      assert Repo.aggregate(from(p in WorkoutPlan, where: p.user_id == ^state.user_id), :count) ==
               1

      assert Repo.aggregate(
               from(r in CoachRecommendation, where: r.user_id == ^state.user_id),
               :count
             ) == 1
    end)
  end

  test "atomic bootstrap plan pin and video replay create one recommendation and session" do
    user = user_fixture()
    slot = required_slot(user)
    built_in = Repo.one!(from(p in WorkoutPlan, where: is_nil(p.user_id), limit: 1))

    assert {:ok, selected} = Workouts.select_bootstrap_home_workout(user, slot, built_in.id)
    assert selected.plan.id == built_in.id

    other = user_fixture()
    other_slot = required_slot(other)
    video = video_fixture()
    token = Ecto.UUID.generate()

    assert {:ok, first} = Workouts.start_bootstrap_home_video(other, other_slot, video.id, token)
    assert {:ok, replay} = Workouts.start_bootstrap_home_video(other, other_slot, video.id, token)
    assert replay.id == first.id

    assert Repo.aggregate(from(r in CoachRecommendation, where: r.user_id == ^other.id), :count) ==
             1

    assert Repo.aggregate(from(s in WorkoutSession, where: s.user_id == ^other.id), :count) == 1
  end

  defp bootstrap_conflicts do
    [
      {"changed submitted state", :invalid_recommendation_selection, fn _user, _slot -> :ok end},
      {"changed submitted slot", :home_selection_changed, fn _user, _slot -> :ok end},
      {"current recommendation", :home_selection_changed,
       fn user, slot ->
         {:ok, _} =
           Workouts.ensure_recommendation(user, Map.take(slot, [:slot_key, :slot_date]))
       end},
      {"historical recommendation", :home_selection_changed,
       fn user, slot ->
         {:ok, _} =
           Workouts.ensure_recommendation(user, %{
             slot_key: "old:" <> slot.slot_key,
             slot_date: Date.add(slot.slot_date, -1)
           })
       end},
      {"owned plan", :home_selection_changed,
       fn user, _slot -> workout_plan_draft_fixture(user) end},
      {"historical session", :home_selection_changed,
       fn user, _slot -> free_form_session_fixture(user) end},
      {"started session", :home_selection_changed,
       fn user, _slot ->
         video = video_fixture()
         {:ok, _} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
       end}
    ]
  end

  defp bootstrap_rows(user) do
    %{
      plans:
        Repo.all(
          from(p in WorkoutPlan,
            where: p.user_id == ^user.id,
            order_by: [asc: p.id],
            select: {p.id, p.state, p.name, p.content_hash, p.design_session_id, p.request_text}
          )
        ),
      recommendations:
        Repo.all(
          from(r in CoachRecommendation,
            where: r.user_id == ^user.id,
            order_by: [asc: r.id],
            select:
              {r.id, r.slot_key, r.slot_date, r.home_workout_plan_id, r.selected_workout_plan_id,
               r.selected_workout_video_id, r.pending_draft_id, r.home_revision}
          )
        ),
      sessions:
        Repo.all(
          from(s in WorkoutSession,
            where: s.user_id == ^user.id,
            order_by: [asc: s.id],
            select:
              {s.id, s.state, s.source_kind, s.plan_id, s.workout_video_id, s.client_session_id,
               s.content_hash, s.display_name_snapshot}
          )
        )
    }
  end

  defp start_shared_bootstrap_task(test_pid, barrier, user, slot, proposed_definition) do
    Task.async(fn ->
      send(test_pid, {:shared_bootstrap_task, self(), barrier})

      receive do
        {:start, ^barrier} ->
          req =
            Req.new(
              adapter: fn request ->
                send(test_pid, {:shared_provider_ready, self(), barrier})

                receive do
                  {:respond, ^barrier} ->
                    {request,
                     %Req.Response{status: 200, body: provider_body(proposed_definition)}}
                end
              end
            )

          Coach.bootstrap_home_draft(user, slot, "First request", opts(req))
      end
    end)
  end

  defp await_shared_provider_ready(%Task{pid: pid}, sandbox_owner, barrier) do
    assert_receive {:shared_bootstrap_task, ^pid, ^barrier}, 10_000
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, sandbox_owner, pid)
    send(pid, {:start, barrier})
    assert_receive {:shared_provider_ready, ^pid, ^barrier}, 10_000
    pid
  end

  defp start_bootstrap_task(test_pid, ready_tag, barrier, state, proposed_definition) do
    Task.async(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      try do
        req =
          Req.new(
            adapter: fn request ->
              send(test_pid, {ready_tag, self(), barrier})

              receive do
                {:respond, ^barrier} ->
                  {request, %Req.Response{status: 200, body: provider_body(proposed_definition)}}
              end
            end
          )

        Coach.bootstrap_home_draft(state.user, state.slot, "A short request", opts(req))
      after
        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end
    end)
  end

  defp await_provider_ready(%Task{pid: pid, ref: ref}, ready_tag, barrier) do
    receive do
      {^ready_tag, ^pid, ^barrier} ->
        pid

      {^ref, result} ->
        flunk("bootstrap returned before readiness: #{inspect(result)}")

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("bootstrap exited before readiness: #{inspect(reason)}")
    after
      10_000 -> flunk("bootstrap did not reach readiness")
    end
  end

  defp outside_sandbox(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp cleanup_committed_user(user_id) do
    outside_sandbox(fn ->
      Repo.delete_all(from(s in WorkoutSession, where: s.user_id == ^user_id))
      Repo.delete_all(from(r in CoachRecommendation, where: r.user_id == ^user_id))
      Repo.delete_all(from(p in WorkoutPlan, where: p.user_id == ^user_id))
      Repo.delete_all(from(s in DesignSession, where: s.user_id == ^user_id))
      Repo.delete_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^user_id))
    end)
  end

  defp required_slot(user) do
    assert {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    slot
  end

  defp request(counter, response, before \\ fn -> :ok end) do
    Req.new(
      plug: fn conn ->
        Agent.update(counter, &(&1 + 1))
        before.()
        Plug.Conn.send_resp(conn, 200, provider_body(response))
      end
    )
  end

  defp request_count(counter), do: Agent.get(counter, & &1)
  defp opts(req), do: [req: req, config: provider_config()]

  defp provider_config,
    do: [
      enabled: true,
      url: "https://provider.test/v1/chat/completions",
      api_key: "test-secret",
      model: "test/model",
      timeout_ms: 12_345
    ]

  defp provider_body(definition),
    do: Jason.encode!(%{"choices" => [%{"message" => %{"content" => Jason.encode!(definition)}}]})

  defp definition(name),
    do: %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "events" => [
        %{"kind" => "work", "reps" => 10, "sec_per_rep" => 12.0, "sec_per_burpee" => 12.0}
      ],
      "rationale" => "bootstrap fixture"
    }
end
