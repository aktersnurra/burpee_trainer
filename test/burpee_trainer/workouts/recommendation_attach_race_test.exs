defmodule BurpeeTrainer.Workouts.RecommendationAttachRaceTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  test "two database connections attach exactly one candidate without an orphan" do
    assert Application.fetch_env!(:burpee_trainer, Repo)[:pool_size] == 5

    state =
      outside_sandbox(fn ->
        user = user_fixture()

        {:ok, recommendation} =
          Workouts.ensure_recommendation(user, %{
            slot_key: "2025-09-01:attach-race-#{System.unique_integer([:positive])}",
            slot_date: ~D[2025-09-01],
            rationale: "Fallback"
          })

        %{user: user, recommendation: recommendation}
      end)

    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(
          from(user in BurpeeTrainer.Accounts.User, where: user.id == ^state.user.id)
        )
      end)
    end)

    barrier = make_ref()
    parent = self()

    tasks =
      for name <- ["Race one", "Race two"] do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:attach_ready, self(), barrier})

            receive do
              {:go, ^barrier} ->
                Workouts.attach_candidate(
                  state.user,
                  state.recommendation.id,
                  candidate_attrs(name)
                )
            end
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)
      end

    task_pids = tasks |> Enum.map(& &1.pid) |> MapSet.new()
    await_ready(task_pids, barrier)
    Enum.each(task_pids, &send(&1, {:go, barrier}))

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, %CoachRecommendation{}}, &1)) == 1

    assert Enum.count(results, fn
             {:error, %{code: :candidate_no_longer_current}} -> true
             _other -> false
           end) == 1

    outside_sandbox(fn ->
      recommendation = Repo.get!(CoachRecommendation, state.recommendation.id)

      drafts =
        Repo.all(
          from(plan in WorkoutPlan,
            where:
              plan.user_id == ^state.user.id and plan.origin == :coach and plan.state == :draft
          )
        )

      assert [%WorkoutPlan{id: draft_id}] = drafts
      assert recommendation.pending_draft_id == draft_id
    end)
  end

  defp await_ready(task_pids, barrier, seen \\ MapSet.new()) do
    if MapSet.equal?(task_pids, seen) do
      :ok
    else
      receive do
        {:attach_ready, pid, ^barrier} ->
          await_ready(task_pids, barrier, MapSet.put(seen, pid))
      after
        2_000 -> flunk("attach tasks did not reach the database-connection barrier")
      end
    end
  end

  defp outside_sandbox(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp candidate_attrs(name) do
    %{
      request_text: "Make a focused workout",
      definition: %{
        "version" => 1,
        "name" => name,
        "burpee_type" => "six_count",
        "target_duration_sec" => 1_200,
        "target_reps" => 10,
        "pacing_style" => "even",
        "rationale" => "Race candidate",
        "events" => [
          %{
            "kind" => "work",
            "reps" => 10,
            "sec_per_burpee" => 120.0,
            "sec_per_rep" => 120.0
          }
        ]
      }
    }
  end
end
