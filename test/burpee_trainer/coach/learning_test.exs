defmodule BurpeeTrainer.Coach.LearningTest do
  use BurpeeTrainer.DataCase, async: false

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Coach.Arm
  alias BurpeeTrainer.Coach.Learning
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "record_session_completed updates coach arms deterministically in tests" do
    {user, session} = user_and_completed_session()
    before_arms = arms_for(user)

    assert :ok = Learning.record_session_completed(user, session)

    after_arms = arms_for(user)

    assert alpha_increased?(before_arms, after_arms)
  end

  test "record_session_completed starts a supervised task and updates arms in async mode" do
    previous_mode = Application.get_env(:burpee_trainer, :coach_learning_mode)
    Application.put_env(:burpee_trainer, :coach_learning_mode, :async)

    on_exit(fn ->
      restore_learning_mode(previous_mode)
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Coach, :update_arms, 2}, false, [])
    end)

    :erlang.trace_pattern({Coach, :update_arms, 2}, true, [])
    :erlang.trace(:all, true, [:call])

    {user, session} = user_and_completed_session()
    before_arms = arms_for(user)

    assert :ok = Learning.record_session_completed(user, session)

    test_pid = self()

    assert_receive {:trace, update_pid, :call, {Coach, :update_arms, [^user, ^session]}}, 500
    assert update_pid != test_pid
    assert_eventually(fn -> alpha_increased?(before_arms, arms_for(user)) end)
  end

  defp user_and_completed_session do
    user = user_fixture()
    plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})

    for _ <- 1..5 do
      session_from_plan_fixture(user, plan, %{
        "burpee_count_planned" => 150,
        "burpee_count_actual" => 150,
        "duration_sec_actual" => 900
      })
    end

    Coach.suggest(user, :six_count)

    session = %WorkoutSession{
      user_id: user.id,
      plan_id: plan.id,
      burpee_type: :six_count,
      burpee_count_planned: 150,
      burpee_count_actual: 150,
      duration_sec_actual: 900
    }

    {user, session}
  end

  defp restore_learning_mode(nil),
    do: Application.delete_env(:burpee_trainer, :coach_learning_mode)

  defp restore_learning_mode(mode),
    do: Application.put_env(:burpee_trainer, :coach_learning_mode, mode)

  defp alpha_increased?(before_arms, after_arms) do
    before_arms
    |> Enum.zip(after_arms)
    |> Enum.any?(fn {before_arm, after_arm} -> after_arm.alpha > before_arm.alpha end)
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      receive do
      after
        10 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp arms_for(user) do
    Repo.all(
      from a in Arm,
        where: a.user_id == ^user.id and a.burpee_type == "six_count",
        order_by: [asc: a.id]
    )
  end
end
