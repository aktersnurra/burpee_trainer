defmodule BurpeeTrainer.Coach.PlannerSelectionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Coach.{Agent, Policy}
  @config [enabled: true, url: "https://provider.test/v1", api_key: "k", model: "m"]

  defp call(name, args),
    do: %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [
              %{"id" => "c", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}
            ]
          }
        }
      ]
    }

  defp final(text),
    do: %{"choices" => [%{"message" => %{"content" => Jason.encode!(%{"reply" => text})}}]}

  defp fixture do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    plan = plan_fixture(scope.user, %{target_reps: 30, target_duration_sec: slot.duration_sec})
    {:ok, selection} = Workouts.ensure_home_selection(scope, slot)
    {scope, slot, plan, selection}
  end

  defp opts(slot), do: [slot: slot, config: @config, req: Req.new(plug: {Req.Test, __MODULE__})]

  defp failure_response(conn, :timeout), do: Req.Test.transport_error(conn, :timeout)

  defp failure_response(conn, :invalid),
    do: Req.Test.json(conn, final(String.duplicate("x", 601)))

  defp failure_response(conn, :loop_cap), do: Req.Test.json(conn, call("goals", %{}))

  defp failure_response(_, cap) when cap in [:run_cap, :daily_cap],
    do: flunk("budget cap allowed a second transport")

  defp assert_failure(:timeout, result),
    do: assert(match?({:error, %{code: :provider_timeout}}, result))

  defp assert_failure(:invalid, result),
    do: assert(result == {:error, :invalid_provider_response})

  defp assert_failure(:loop_cap, result), do: assert(result == {:error, :agent_budget_exhausted})

  defp assert_failure(cap, result) when cap in [:run_cap, :daily_cap],
    do: assert(match?({:error, %{code: :llm_budget_exhausted}}, result))

  defp transport_count(:loop_cap), do: 6
  defp transport_count(cap) when cap in [:run_cap, :daily_cap], do: 1
  defp transport_count(_), do: 2

  defp selection_call(plan),
    do: call("select_workout", %{"plan_id" => plan.id, "rationale" => "Ready"})

  defp proposal_call(_plan) do
    call("propose_workout", %{
      "reps" => 10,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil,
      "layout" => %{
        "name" => "Staged proposal",
        "rationale" => "Ready",
        "phases" => [
          %{
            "sets" => [
              %{"reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 5},
              %{"reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 5}
            ],
            "rests" => [%{"share" => 1}]
          }
        ]
      }
    })
  end

  defp failure_opts(slot, :run_cap), do: Keyword.put(opts(slot), :budget, run_cap: 1)
  defp failure_opts(slot, :daily_cap), do: Keyword.put(opts(slot), :budget, daily_cap: 1)
  defp failure_opts(slot, _), do: opts(slot)
  defp first_call(:selection, plan), do: selection_call(plan)
  defp first_call(:proposal, plan), do: proposal_call(plan)

  for tool <- [:selection, :proposal],
      failure <- [:timeout, :invalid, :run_cap, :daily_cap, :loop_cap] do
    test "successful #{tool} remains staged after #{failure}" do
      {scope, slot, plan, before} = fixture()
      failure = unquote(failure)
      tool = unquote(tool)
      run_id = Ecto.UUID.generate()
      pid = start_supervised!({Elixir.Agent, fn -> 0 end})

      Req.Test.stub(__MODULE__, fn conn ->
        index = Elixir.Agent.get_and_update(pid, &{&1, &1 + 1})

        if index == 0 do
          Req.Test.json(conn, first_call(tool, plan))
        else
          assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
          failure_response(conn, failure)
        end
      end)

      options = failure_opts(slot, failure)

      assert_failure(
        failure,
        Agent.run(scope, :planner, nil, Keyword.put(options, :run_id, run_id))
      )

      assert Elixir.Agent.get(pid, & &1) == transport_count(failure)
      assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
      assert_candidate(tool, scope, run_id)
    end
  end

  defp assert_candidate(:selection, _, _), do: :ok

  # A staged proposal is persisted only when the run completes and selects it.
  defp assert_candidate(:proposal, scope, run_id) do
    refute Repo.get_by(BurpeeTrainer.Workouts.WorkoutPlan, approval_key: run_id <> ":1")
    assert Workouts.list_library(scope) |> Enum.all?(&(&1.name != "Staged proposal"))
  end

  for stage <- [:first, :final], choice <- [:same, :other] do
    test "original CAS wins over owner #{choice} selection during #{stage} provider request" do
      stage = unquote(stage)
      choice = unquote(choice)
      {scope, slot, plan, before} = fixture()
      owner = self()
      pid = start_supervised!({Elixir.Agent, fn -> 0 end})

      Req.Test.stub(__MODULE__, fn conn ->
        index = Elixir.Agent.get_and_update(pid, &{&1, &1 + 1})

        if barrier_index(stage) == index do
          send(owner, {:provider_waiting, self()})

          receive do
            :owner_finished -> :ok
          end
        end

        if index == 0,
          do: Req.Test.json(conn, selection_call(plan)),
          else: Req.Test.json(conn, final("Ready"))
      end)

      task = Task.async(fn -> Agent.run(scope, :planner, nil, opts(slot)) end)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
      Req.Test.allow(__MODULE__, self(), task.pid)
      assert_receive {:provider_waiting, provider}, 1000

      owner_plan =
        plan_fixture(scope.user, %{target_reps: 20, target_duration_sec: slot.duration_sec})

      assert {:ok, owner_selection} =
               Workouts.select_home_workout(scope, before, owner_id(choice, before, owner_plan))

      send(provider, :owner_finished)
      assert {:error, %{code: :home_selection_changed}} = Task.await(task)
      assert {:ok, ^owner_selection} = Workouts.ensure_home_selection(scope, slot)
    end
  end

  defp barrier_index(:first), do: 0
  defp barrier_index(:final), do: 1
  defp owner_id(:same, before, _), do: before.plan.id
  defp owner_id(:other, _, plan), do: plan.id

  test "successful proposal is published canonically and selected only at final completion" do
    {scope, slot, plan, before} = fixture()
    run_id = Ecto.UUID.generate()
    pid = start_supervised!({Elixir.Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      index = Elixir.Agent.get_and_update(pid, &{&1, &1 + 1})

      if index == 0 do
        Req.Test.json(conn, proposal_call(plan))
      else
        assert_candidate(:proposal, scope, run_id)
        assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
        Req.Test.json(conn, final("Ready"))
      end
    end)

    assert {:ok, %{reply: "Ready"}} =
             Agent.run(scope, :planner, nil, Keyword.put(opts(slot), :run_id, run_id))

    candidate = Repo.get_by!(BurpeeTrainer.Workouts.WorkoutPlan, approval_key: run_id <> ":1")
    assert candidate.state == :published
    assert candidate.target_reps == 10
    assert {:ok, after_selection} = Workouts.ensure_home_selection(scope, slot)
    assert after_selection.plan.id == candidate.id
    assert after_selection.home_revision == before.home_revision + 1
  end

  test "a superseded proposal is never persisted" do
    {scope, slot, plan, before} = fixture()
    run_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {Elixir.Agent, fn -> [proposal_call(plan), selection_call(plan), final("Ready")] end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end))
    end)

    assert {:ok, %{reply: "Ready"}} =
             Agent.run(scope, :planner, nil, Keyword.put(opts(slot), :run_id, run_id))

    refute Repo.get_by(BurpeeTrainer.Workouts.WorkoutPlan, approval_key: run_id <> ":1")
    assert {:ok, after_selection} = Workouts.ensure_home_selection(scope, slot)
    assert after_selection.plan.id == plan.id
    assert after_selection.home_revision == before.home_revision + 1
  end

  test "a proposal is not persisted when the owner changed the selection during the run" do
    {scope, slot, plan, before} = fixture()
    run_id = Ecto.UUID.generate()
    pid = start_supervised!({Elixir.Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      case Elixir.Agent.get_and_update(pid, &{&1, &1 + 1}) do
        0 ->
          Req.Test.json(conn, proposal_call(plan))

        _ ->
          {:ok, _} = Workouts.select_home_workout(scope, before, plan.id)
          Req.Test.json(conn, final("Ready"))
      end
    end)

    assert {:error, %{code: :home_selection_changed}} =
             Agent.run(scope, :planner, nil, Keyword.put(opts(slot), :run_id, run_id))

    refute Repo.get_by(BurpeeTrainer.Workouts.WorkoutPlan, approval_key: run_id <> ":1")
    assert {:ok, %{plan: %{id: id}}} = Workouts.ensure_home_selection(scope, slot)
    assert id == plan.id
  end

  test "a planner reply that chose nothing is reminded once and then selects" do
    {scope, slot, plan, before} = fixture()

    pid =
      start_supervised!(
        {Elixir.Agent, fn -> [final("Done"), selection_call(plan), final("Ready")] end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end))
    end)

    assert {:ok, %{reply: "Ready"}} = Agent.run(scope, :planner, nil, opts(slot))
    assert {:ok, after_selection} = Workouts.ensure_home_selection(scope, slot)
    assert after_selection.plan.id == plan.id
    assert after_selection.home_revision == before.home_revision + 1
  end

  test "a planner that still chooses nothing after the reminder fails and leaves Home as it was" do
    {scope, slot, _plan, before} = fixture()
    pid = start_supervised!({Elixir.Agent, fn -> [final("Done"), final("Done")] end})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end))
    end)

    assert {:error, :no_selection} = Agent.run(scope, :planner, nil, opts(slot))
    assert Elixir.Agent.get(pid, & &1) == []
    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
  end

  test "successful completion commits only the last staged selection" do
    {scope, slot, plan, before} = fixture()

    pid =
      start_supervised!(
        {Elixir.Agent,
         fn ->
           [
             call("select_workout", %{"plan_id" => before.plan.id, "rationale" => "First"}),
             call("select_workout", %{"plan_id" => plan.id, "rationale" => "Last"}),
             final("Ready")
           ]
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Elixir.Agent.get_and_update(pid, fn [head | rest] -> {head, rest} end))
    end)

    assert {:ok, %{reply: "Ready"}} = Agent.run(scope, :planner, nil, opts(slot))
    assert {:ok, after_selection} = Workouts.ensure_home_selection(scope, slot)
    assert after_selection.plan.id == plan.id
    assert after_selection.home_revision == before.home_revision + 1
  end
end
