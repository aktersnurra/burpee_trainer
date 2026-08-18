defmodule BurpeeTrainer.Fixtures do
  import Ecto.Query

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
    suffix =
      [System.system_time(:nanosecond), System.unique_integer([:positive, :monotonic])]
      |> Enum.map(&Integer.to_string(&1, 36))
      |> Enum.join("_")

    {:ok, user} =
      attrs
      |> Enum.into(%{
        "username" => "user_#{suffix}",
        "password" => "correct-horse-battery-staple"
      })
      |> Accounts.register_user()

    user
  end

  @doc "Build a valid published workout through the state-specific lifecycle APIs."
  def plan_fixture(user, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    definition = fixture_workout_definition(attrs)

    {:ok, draft} =
      Workouts.create_user_draft(user, %{
        "definition" => definition,
        "request_text" => Map.get(attrs, "request_text")
      })

    {:ok, plan} = Workouts.publish_draft(user, draft.id)
    plan
  end

  @doc "Build a valid user-owned draft through the state-specific lifecycle API."
  def workout_plan_draft_fixture(user, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    {:ok, draft} =
      Workouts.create_user_draft(user, %{
        "definition" => fixture_workout_definition(attrs),
        "request_text" => Map.get(attrs, "request_text")
      })

    draft
  end

  @doc "Build a completed session tied to a plan."
  def session_from_plan_fixture(user, plan, attrs \\ %{}) do
    defaults = %{
      "burpee_count_actual" => 30,
      "duration_sec_actual" => 118
    }

    attrs = Map.merge(defaults, stringify_keys(attrs))
    inserted_at = Map.get(attrs, "inserted_at")
    client_session_id = Map.get(attrs, "client_session_id", Ecto.UUID.generate())

    completion_attrs =
      Map.take(attrs, [
        "burpee_count_actual",
        "duration_sec_actual",
        "note_pre",
        "note_post",
        "mood",
        "tags",
        "context_low_energy",
        "context_high_energy",
        "context_heat_affected",
        "primary_limiter",
        "preference_feedback"
      ])

    {:ok, started} = Workouts.start_plan(user, plan.id, client_session_id)
    {:ok, session} = Workouts.complete_session(user, started.id, completion_attrs, :timed)

    if match?(%DateTime{}, inserted_at) do
      BurpeeTrainer.Repo.update_all(
        from(candidate in BurpeeTrainer.Workouts.WorkoutSession,
          where: candidate.id == ^session.id
        ),
        set: [inserted_at: inserted_at, completed_at: DateTime.truncate(inserted_at, :second)]
      )

      BurpeeTrainer.Repo.reload(session)
    else
      session
    end
  end

  @doc """
  Build a free-form session.
  """
  def free_form_session_fixture(user, attrs \\ %{}) do
    defaults = %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 25,
      "duration_sec_actual" => 100,
      "completed_at" => DateTime.add(DateTime.utc_now(:second), -1, :second)
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

  @doc """
  Build a video. No user scoping — videos are global.
  """
  def video_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      name: "Test Video #{n}",
      filename: "video_#{n}.mp4",
      burpee_type: :six_count,
      duration_sec: 1200,
      burpee_count: nil,
      available: true,
      format: :follow_along
    }

    {:ok, video} = BurpeeTrainer.Videos.create_video(Map.merge(defaults, attrs))
    video
  end

  defp fixture_workout_definition(attrs) do
    case Map.get(attrs, "definition") || Map.get(attrs, "definition_json") do
      definition when is_map(definition) ->
        definition

      _missing ->
        source = Map.get(attrs, "source_json", %{})
        suffix = System.unique_integer([:positive, :monotonic])
        target_reps = fixture_target_reps(attrs, source)
        target_duration_sec = fixture_target_duration_sec(attrs, source)

        %{
          "version" => 1,
          "name" => Map.get(attrs, "name", "Test plan #{suffix}"),
          "burpee_type" =>
            Map.get(attrs, "burpee_type", Map.get(source, "burpee_type", "six_count")),
          "target_reps" => target_reps,
          "target_duration_sec" => target_duration_sec,
          "pacing_style" => Map.get(attrs, "pacing_style", Map.get(source, "kind", "even")),
          "events" => fixture_definition_events(target_reps, target_duration_sec),
          "rationale" => Map.get(attrs, "rationale", "Lifecycle fixture #{suffix}.")
        }
    end
  end

  defp fixture_target_reps(attrs, source) do
    Map.get(attrs, "target_reps") || Map.get(attrs, "burpee_count_target") ||
      Map.get(source, "target_reps") || 30
  end

  defp fixture_target_duration_sec(attrs, source) do
    Map.get(attrs, "target_duration_sec") || Map.get(attrs, "duration_sec") ||
      duration_from_minutes(Map.get(attrs, "target_duration_min")) ||
      Map.get(source, "duration_sec") || 1_200
  end

  defp duration_from_minutes(minutes) when is_integer(minutes) and minutes > 0, do: minutes * 60
  defp duration_from_minutes(_minutes), do: nil

  defp fixture_definition_events(target_reps, target_duration_sec) do
    total_us = target_duration_sec * 1_000_000
    base_us = div(total_us, target_reps)
    longer_reps = rem(total_us, target_reps)

    []
    |> maybe_add_definition_work(longer_reps, base_us + 1)
    |> maybe_add_definition_work(target_reps - longer_reps, base_us)
  end

  defp maybe_add_definition_work(events, reps, sec_per_rep_us) when reps > 0 do
    sec_per_rep = sec_per_rep_us / 1_000_000

    events ++
      [
        %{
          "kind" => "work",
          "reps" => reps,
          "sec_per_rep" => sec_per_rep,
          "sec_per_burpee" => sec_per_rep
        }
      ]
  end

  defp maybe_add_definition_work(events, _reps, _sec_per_rep_us), do: events

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
