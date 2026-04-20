defmodule BurpeeTrainer.Fixtures do
  @moduledoc """
  Builders for test data. Each builder accepts an attribute override map
  so tests can override just the fields they care about. All builders
  persist via the corresponding context so constraints and changesets
  are exercised.
  """

  alias BurpeeTrainer.{Accounts, Goals, Workouts}

  @doc """
  Build and register a user. Username defaults are uniquified via
  `System.unique_integer/1` so fixtures can be called many times per
  test.
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        "username" => "user_#{n}",
        "password" => "correct-horse-battery-staple"
      })
      |> Accounts.register_user()

    user
  end

  @doc """
  Build a plan with one block of three sets by default. Override
  `"blocks"` to supply a custom structure.
  """
  def plan_fixture(user, attrs \\ %{}) do
    defaults = %{
      "name" => "Test plan",
      "burpee_type" => "six_count",
      "warmup_enabled" => false,
      "shave_off_sec" => 0,
      "shave_off_block_count" => 0,
      "blocks" => [
        %{
          "position" => 1,
          "repeat_count" => 1,
          "sets" => [
            %{
              "position" => 1,
              "burpee_count" => 10,
              "sec_per_rep" => 6.0,
              "sec_per_burpee" => 3.0,
              "end_of_set_rest" => 30
            },
            %{
              "position" => 2,
              "burpee_count" => 10,
              "sec_per_rep" => 6.0,
              "sec_per_burpee" => 3.0,
              "end_of_set_rest" => 30
            },
            %{
              "position" => 3,
              "burpee_count" => 10,
              "sec_per_rep" => 6.0,
              "sec_per_burpee" => 3.0,
              "end_of_set_rest" => 0
            }
          ]
        }
      ]
    }

    {:ok, plan} = Workouts.create_plan(user, Map.merge(defaults, stringify_keys(attrs)))
    plan
  end

  @doc """
  Build a completed session tied to a plan.
  """
  def session_from_plan_fixture(user, plan, attrs \\ %{}) do
    defaults = %{
      "burpee_type" => to_string(plan.burpee_type),
      "burpee_count_planned" => 30,
      "duration_sec_planned" => 120,
      "burpee_count_actual" => 30,
      "duration_sec_actual" => 118
    }

    {:ok, session} =
      Workouts.create_session_from_plan(user, plan, Map.merge(defaults, stringify_keys(attrs)))

    session
  end

  @doc """
  Build a free-form session.
  """
  def free_form_session_fixture(user, attrs \\ %{}) do
    defaults = %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 25,
      "duration_sec_actual" => 100
    }

    {:ok, session} =
      Workouts.create_free_form_session(user, Map.merge(defaults, stringify_keys(attrs)))

    session
  end

  @doc """
  Build an active goal. Defaults to a target 4 weeks out from today
  with a 50 → 70 rep progression.
  """
  def goal_fixture(user, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 70,
      "duration_sec_target" => 300,
      "date_target" => Date.to_iso8601(Date.add(today, 28)),
      "burpee_count_baseline" => 50,
      "duration_sec_baseline" => 240,
      "date_baseline" => Date.to_iso8601(today)
    }

    {:ok, goal} = Goals.create_goal(user, Map.merge(defaults, stringify_keys(attrs)))
    goal
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
