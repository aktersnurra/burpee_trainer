defmodule BurpeeTrainer.Fixtures do
  import Ecto.Query

  @moduledoc """
  Builders for test data. Each builder accepts an attribute override map
  so tests can override just the fields they care about. All builders
  persist via the corresponding context so constraints and changesets
  are exercised.
  """

  alias BurpeeTrainer.{Accounts, PlanCompiler, Workouts}
  alias BurpeeTrainer.PlanCompiler.{ProgramHash, WorkoutDefinition}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @doc """
  Build and register a user. Username defaults are uniquified via
  `System.unique_integer/1` so fixtures can be called many times per
  test.

  The user is established: they signed up long ago, so the current week is a regular
  training week whatever day the suite runs. Use `sign_up_at/2` for a sign-up week.
  """
  def user_fixture(attrs \\ %{}) do
    suffix =
      [System.system_time(:nanosecond), System.unique_integer([:positive, :monotonic])]
      |> Enum.map(&Integer.to_string(&1, 36))
      |> Enum.join("_")

    {:ok, user} =
      attrs
      |> Enum.into(%{
        "username" => "user_#{suffix}"
      })
      |> Accounts.create_user()

    sign_up_at(user, ~U[2024-01-01 00:00:00Z])
  end

  @doc "Set when the user signed up, which decides their pro-rated sign-up week."
  def sign_up_at(%Accounts.User{id: id}, %DateTime{} = signed_up_at) do
    BurpeeTrainer.Repo.update_all(from(user in Accounts.User, where: user.id == ^id),
      set: [inserted_at: DateTime.truncate(signed_up_at, :second)]
    )

    BurpeeTrainer.Repo.get!(Accounts.User, id)
  end

  @doc "Build an authorization scope around a persisted fixture user."
  def scope_fixture(attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> BurpeeTrainer.Accounts.Scope.for_user()
  end

  @doc "Count the LLM calls recorded for a scope's user."
  def llm_call_count(%BurpeeTrainer.Accounts.Scope{user: %{id: user_id}}) do
    BurpeeTrainer.Repo.aggregate(
      from(call in BurpeeTrainer.Coach.LlmCall, where: call.user_id == ^user_id),
      :count
    )
  end

  @doc "Store a current coach summary for the user (written now, so it needs no refresh)."
  def summary_fixture(user, text \\ "Steady progress toward the goal.") do
    {:ok, summary} =
      BurpeeTrainer.Coach.Summary.store(BurpeeTrainer.Accounts.Scope.for_user(user), %{
        text: text,
        metric_ids: [],
        source: :llm
      })

    summary
  end

  @doc "Build a valid published workout through the compiler-backed persistence path."
  def plan_fixture(user, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    insert_plan!(
      user,
      fixture_workout_definition(attrs),
      Map.get(attrs, "request_text"),
      :published
    )
  end

  @doc "Build a valid user-owned draft through the compiler-backed persistence path."
  def workout_plan_draft_fixture(user, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    insert_plan!(user, fixture_workout_definition(attrs), Map.get(attrs, "request_text"), :draft)
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

    {:ok, started} =
      Workouts.start_plan(BurpeeTrainer.Accounts.Scope.for_user(user), plan.id, client_session_id)

    {:ok, session} =
      Workouts.complete_session(
        BurpeeTrainer.Accounts.Scope.for_user(user),
        started.id,
        completion_attrs,
        :timed
      )

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

  @doc "Insert a completed manual history row (legacy manual logs have no creation UI)."
  def free_form_session_fixture(user, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    %BurpeeTrainer.Workouts.WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged
    }
    |> Ecto.Changeset.change(
      burpee_type: String.to_existing_atom(Map.get(attrs, "burpee_type", "six_count")),
      burpee_count_actual: Map.get(attrs, "burpee_count_actual", 25),
      duration_sec_actual: Map.get(attrs, "duration_sec_actual", 100),
      completed_at:
        Map.get(attrs, "completed_at", DateTime.add(DateTime.utc_now(:second), -1, :second))
    )
    |> BurpeeTrainer.Repo.insert!()
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

    %BurpeeTrainer.Goals.Goal{user_id: user.id}
    |> BurpeeTrainer.Goals.Goal.changeset(Map.merge(defaults, stringify_keys(attrs)))
    |> BurpeeTrainer.Repo.insert!()
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

  defp insert_plan!(user, definition_attrs, request_text, state) do
    {:ok, definition} = WorkoutDefinition.new(definition_attrs)
    {:ok, program} = PlanCompiler.compile(definition)

    content = %{
      name: definition.name,
      request_text: request_text,
      definition_json: WorkoutDefinition.canonical_map(definition),
      program_json: ProgramHash.canonical_map(program),
      content_hash: ProgramHash.hash(program),
      burpee_type: definition.burpee_type,
      target_reps: definition.target_reps,
      target_duration_sec: definition.target_duration_sec
    }

    draft =
      %WorkoutPlan{user_id: user.id, origin: :user, state: :draft}
      |> WorkoutPlan.new_draft_changeset(content)
      |> BurpeeTrainer.Repo.insert!()

    case state do
      :draft ->
        draft

      :published ->
        draft
        |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second))
        |> BurpeeTrainer.Repo.update!()
    end
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
