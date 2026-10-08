defmodule BurpeeTrainer.Workouts do
  @moduledoc """
  Context for workout source plans and workout sessions.
  All queries are scoped by `user_id`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias BurpeeTrainer.Accounts.{Scope, User}
  alias BurpeeTrainer.Coach.Policy

  alias BurpeeTrainer.{PlanCompiler, UserTime}

  alias BurpeeTrainer.PlanCompiler.{ProgramHash, WorkoutDefinition}

  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Milestones
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Scoring
  alias BurpeeTrainer.Workouts.PaceConsistency

  alias BurpeeTrainer.Workouts.{
    CoachRecommendation,
    Error,
    HomeSelection,
    PoseCaptureRun,
    PoseTraceChunk,
    WorkoutPlan,
    WorkoutSession,
    WorkoutVideo
  }

  # A session is eligible to set a pace PR only when it is a genuine effort:
  # a full-length-ish bout (≤ 20 min) of at least this many burpees.
  @pace_pr_min_count 20
  @pace_pr_max_duration 1200
  @pose_chunk_identity_fields [
    :segment,
    :chunk_index,
    :started_at_ms,
    :ended_at_ms,
    :sample_count,
    :payload_json,
    :payload_digest
  ]

  # ---------------------------------------------------------------------------
  # Plans
  # ---------------------------------------------------------------------------

  @doc "Lists the user's published plans together with shared published built-ins."
  @spec list_library(Scope.t()) :: [WorkoutPlan.t()]
  def list_library(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from(plan in WorkoutPlan,
        where:
          plan.state == :published and
            (plan.user_id == ^user_id or (is_nil(plan.user_id) and plan.origin == :built_in)),
        order_by: [asc: plan.name, asc: plan.id]
      )
    )
  end

  @type home_entry_state :: :bootstrap | :existing

  @doc "Classifies whether a workout-needed Home slot has any persisted user evidence."
  @spec home_entry_state(Scope.t(), Policy.slot()) ::
          {:ok, home_entry_state()} | {:error, Error.t()}
  def home_entry_state(
        %Scope{user: %User{id: user_id}},
        %{slot_key: slot_key, slot_date: %Date{}, home_state: :workout_needed}
      )
      when is_binary(slot_key) and slot_key != "" do
    try do
      evidence? =
        Enum.any?([
          current_recommendation_exists?(user_id, slot_key),
          historical_recommendation_exists?(user_id),
          owned_plan_exists?(user_id),
          session_exists?(user_id)
        ])

      {:ok, if(evidence?, do: :existing, else: :bootstrap)}
    rescue
      _error -> {:error, Error.new(:home_entry_state_unavailable)}
    end
  end

  def home_entry_state(%Scope{}, _slot),
    do: {:error, Error.new(:invalid_recommendation_selection)}

  # The slot and all evidence are re-read in lifecycle transactions; a presentation-time
  # bootstrap classification is never sufficient to authorize a first-use write.
  defp verified_bootstrap_slot(
         user,
         %{slot_key: slot_key, slot_date: %Date{} = slot_date, home_state: :workout_needed}
       )
       when is_binary(slot_key) and slot_key != "" do
    with {:ok, current} <- Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second)),
         true <-
           current.slot_key == slot_key and current.slot_date == slot_date and
             current.home_state == :workout_needed,
         {:ok, :bootstrap} <- home_entry_state(Scope.for_user(user), current) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, Error.new(:home_selection_changed)}
    end
  end

  defp verified_bootstrap_slot(_user, _slot),
    do: {:error, Error.new(:invalid_recommendation_selection)}

  defp current_recommendation_exists?(user_id, slot_key) do
    Repo.exists?(
      from(recommendation in CoachRecommendation,
        where: recommendation.user_id == ^user_id and recommendation.slot_key == ^slot_key
      )
    )
  end

  defp historical_recommendation_exists?(user_id) do
    Repo.exists?(
      from(recommendation in CoachRecommendation, where: recommendation.user_id == ^user_id)
    )
  end

  defp owned_plan_exists?(user_id) do
    Repo.exists?(from(plan in WorkoutPlan, where: plan.user_id == ^user_id))
  end

  defp session_exists?(user_id) do
    Repo.exists?(from(session in WorkoutSession, where: session.user_id == ^user_id))
  end

  @doc "Reads a verified owned slot pointer without repairing or creating it."
  @spec current_home_selection(Scope.t(), Policy.slot()) :: HomeSelection.t() | nil
  def current_home_selection(
        %Scope{user: %User{} = user},
        %{slot_key: key, slot_date: %Date{} = date, home_state: :workout_needed}
      )
      when is_binary(key) and key != "" do
    with %CoachRecommendation{} = recommendation <-
           Repo.get_by(CoachRecommendation, user_id: user.id, slot_key: key, slot_date: date),
         {:ok, plan} <- verified_home_plan(user, recommendation.home_workout_plan_id) do
      HomeSelection.new(recommendation, plan)
    else
      _ -> nil
    end
  end

  def current_home_selection(%Scope{}, _slot), do: nil

  @doc "Pins the first available Home workout without replacing a valid existing pin."
  @spec ensure_home_selection(Scope.t(), Policy.slot()) ::
          {:ok, HomeSelection.t()} | {:error, Error.t()}
  def ensure_home_selection(%Scope{user: %User{} = user} = scope, slot) do
    immediate_lifecycle_transaction(fn ->
      with {:ok, r} <- ensure_recommendation(scope, Map.take(slot, [:slot_key, :slot_date])),
           {:ok, r} <- ensure_recommendation_selection_available(scope, r.id) do
        case verified_home_plan(user, r.home_workout_plan_id) do
          {:ok, plan} ->
            {:ok, HomeSelection.new(r, plan)}

          {:error, _} ->
            with {:ok, plan} <- initial_home_plan(user, r),
                 {:ok, pinned} <- write_home_pointer(r, plan.id) do
              {:ok, HomeSelection.new(pinned, plan)}
            end
        end
      end
    end)
  end

  @doc "Recovers a genuinely missing Home selection after an explicit published plan choice."
  @spec recover_home_workout_selection(Scope.t(), Policy.slot(), pos_integer()) ::
          {:ok, HomeSelection.t()} | {:error, Error.t()}
  def recover_home_workout_selection(%Scope{user: %User{} = user} = scope, slot, plan_id) do
    immediate_lifecycle_transaction(fn ->
      with {:ok, current, recommendation} <- verified_recovery_slot(scope, slot),
           :ok <- no_other_started_session(user),
           :ok <- missing_ensurable_selection(user, recommendation),
           {:ok, plan} <- get_library_plan(scope, plan_id),
           :ok <- verify_stored_draft(plan),
           {:ok, recommendation} <-
             recovery_recommendation(scope, current, recommendation, {:plan, plan.id}),
           {:ok, pinned} <- write_home_pointer(recommendation, plan.id) do
        {:ok, HomeSelection.new(pinned, plan)}
      end
    end)
  end

  @doc "Starts an explicitly chosen recovery video with exact source/hash/token replay."
  @spec start_recovery_home_video(Scope.t(), Policy.slot(), pos_integer(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def start_recovery_home_video(%Scope{user: %User{} = user} = scope, slot, video_id, token)
      when is_integer(video_id) and video_id > 0 do
    immediate_lifecycle_transaction(fn ->
      with :ok <- valid_start_token(token),
           {:ok, current, recommendation} <- verified_recovery_slot(scope, slot),
           {:ok, video} <- get_available_video_for_start(video_id),
           {:ok, _snapshot, hash} <- canonical_video_snapshot(video) do
        case existing_start(user.id, token, :video, video.id, hash) do
          {:existing, session} ->
            case recommendation do
              %CoachRecommendation{selected_workout_video_id: ^video_id} -> {:ok, session}
              _ -> {:error, Error.new(:home_selection_changed)}
            end

          :new ->
            with :ok <- no_other_started_session(user),
                 :ok <- missing_ensurable_selection(user, recommendation),
                 {:ok, recommendation} <-
                   recovery_recommendation(scope, current, recommendation, {:video, video.id}),
                 {:ok, _changed} <- write_home_pointer(recommendation, nil) do
              start_video(scope, video.id, token)
            end

          {:error, %Error{} = error} ->
            {:error, error}
        end
      end
    end)
  end

  def start_recovery_home_video(%Scope{}, _slot, _video_id, _token),
    do: {:error, Error.new(:source_unavailable)}

  # Reuse the existing first-use evidence classification inside the current-slot
  # transaction, with no valid Home pointer. Home.facts observes the same owned evidence.
  # The immediate transaction prevents a concurrent command from replacing the winner.
  defp verified_recovery_slot(
         %Scope{user: %User{id: user_id}} = scope,
         %{slot_key: key, slot_date: %Date{} = date, home_state: :workout_needed}
       )
       when is_binary(key) and key != "" do
    with {:ok, current} <- Policy.required_slot(scope, lifecycle_now()),
         true <-
           current.slot_key == key and current.slot_date == date and
             current.home_state == :workout_needed,
         {:ok, :existing} <- home_entry_state(scope, current),
         nil <- current_home_selection(scope, current) do
      {:ok, current,
       Repo.get_by(CoachRecommendation, user_id: user_id, slot_key: key, slot_date: date)}
    else
      _ -> {:error, Error.new(:home_selection_changed)}
    end
  end

  defp verified_recovery_slot(_scope, _slot),
    do: {:error, Error.new(:invalid_recommendation_selection)}

  # Do not broaden normal first-use authorization or recover a slot which the loader
  # could already pin. In particular, a revision-zero pending candidate remains normal.
  defp missing_ensurable_selection(user, recommendation) do
    # ensure_home_selection first requires the real fallback-backed slot row even
    # when a recommendation already exists. Absence of that fallback is genuine
    # choose eligibility; do not mistake an unpinned selected source for a winner.
    result =
      with {:ok, _fallback} <- built_in_fallback() do
        case recommendation do
          nil -> verified_home_fallback()
          %CoachRecommendation{} = r -> initial_home_plan(user, r)
        end
      end

    case result do
      {:ok, _plan} -> {:error, Error.new(:home_selection_changed)}
      {:error, %Error{}} -> :ok
    end
  end

  # Recovery has no fallback dependency: the real validated explicit source backs the
  # slot row. Reuse the exact selection changeset, unique slot constraint and pin writer.
  defp recovery_recommendation(%Scope{user: %User{id: user_id}}, slot, recommendation, source) do
    attrs =
      case source do
        {:plan, id} -> %{selected_workout_plan_id: id, selected_workout_video_id: nil}
        {:video, id} -> %{selected_workout_plan_id: nil, selected_workout_video_id: id}
      end

    result =
      case recommendation do
        nil ->
          %CoachRecommendation{user_id: user_id}
          |> CoachRecommendation.changeset(
            Map.merge(attrs, Map.take(slot, [:slot_key, :slot_date]))
          )
          |> Repo.insert()

        %CoachRecommendation{} = r ->
          r |> CoachRecommendation.selection_changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, r} -> {:ok, r}
      {:error, _changeset} -> {:error, Error.new(:home_selection_changed)}
    end
  end

  @doc "Lists filtered first-use alternatives without creating a recommendation."
  @spec bootstrap_alternatives(Scope.t(), Policy.slot(), map(), :workouts | :videos) :: [map()]
  def bootstrap_alternatives(%Scope{user: %User{} = user} = scope, slot, filters, :workouts) do
    with :ok <- verified_bootstrap_slot(user, slot) do
      BurpeeTrainer.Coach.Catalog.order_plans(
        list_library(scope),
        [],
        slot,
        BurpeeTrainer.Levels.current_level([])
      )
      |> BurpeeTrainer.Coach.Catalog.filter(filters, &BurpeeTrainer.Coach.Catalog.plan_level/1)
    else
      _ -> []
    end
  end

  def bootstrap_alternatives(%Scope{user: %User{} = user}, slot, filters, :videos) do
    with :ok <- verified_bootstrap_slot(user, slot) do
      BurpeeTrainer.Videos.list_home_videos()
      |> BurpeeTrainer.Coach.Catalog.order_videos()
      |> BurpeeTrainer.Coach.Catalog.filter(filters, &BurpeeTrainer.Coach.Catalog.video_level/1)
    else
      _ -> []
    end
  end

  @doc "Pins a first-use Home plan atomically."
  @spec select_bootstrap_home_workout(Scope.t(), Policy.slot(), pos_integer()) ::
          {:ok, HomeSelection.t()} | {:error, Error.t()}
  def select_bootstrap_home_workout(%Scope{user: %User{} = user} = scope, slot, plan_id) do
    immediate_lifecycle_transaction(fn ->
      with :ok <- verified_bootstrap_slot(user, slot),
           :ok <- no_other_started_session(user),
           {:ok, plan} <- get_library_plan(scope, plan_id),
           :ok <- verify_stored_draft(plan),
           {:ok, recommendation} <-
             ensure_recommendation(scope, Map.take(slot, [:slot_key, :slot_date])),
           {:ok, changed} <- write_home_pointer(recommendation, plan.id) do
        {:ok, HomeSelection.new(changed, plan)}
      end
    end)
  end

  @doc "Starts a first-use Home video, preserving exact-token replay semantics."
  @spec start_bootstrap_home_video(Scope.t(), Policy.slot(), pos_integer(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def start_bootstrap_home_video(%Scope{user: %User{} = user}, slot, video_id, token) do
    with {:ok, video} <- get_available_video_for_start(video_id),
         {:ok, _snapshot, hash} <- canonical_video_snapshot(video) do
      immediate_lifecycle_transaction(fn ->
        with :ok <- valid_start_token(token) do
          case existing_start(user.id, token, :video, video.id, hash) do
            {:existing, session} -> {:ok, session}
            replay -> bootstrap_video_start(user, slot, video, token, replay)
          end
        end
      end)
    end
  end

  defp bootstrap_video_start(user, slot, video, token, :new) do
    with :ok <- verified_bootstrap_slot(user, slot),
         :ok <- no_other_started_session(user),
         {:ok, _recommendation} <-
           ensure_recommendation(Scope.for_user(user), Map.take(slot, [:slot_key, :slot_date])) do
      start_video(Scope.for_user(user), video.id, token)
    end
  end

  defp bootstrap_video_start(_user, _slot, _video, _token, {:error, %Error{} = error}),
    do: {:error, error}

  @doc "Changes the Home pointer only if the reviewed selection is still current."
  @spec select_home_workout(Scope.t(), HomeSelection.t(), pos_integer()) ::
          {:ok, HomeSelection.t()} | {:error, Error.t()}
  def select_home_workout(%Scope{user: %User{} = user}, %HomeSelection{} = expected, id) do
    immediate_lifecycle_transaction(fn ->
      with {:ok, r} <- home_recommendation(user, expected),
           {:ok, plan} <- selectable_home_plan(user, r, id),
           :ok <- verify_stored_draft(plan),
           {:ok, changed} <- write_home_pointer(r, plan.id) do
        {:ok, HomeSelection.new(changed, plan)}
      end
    end)
  end

  @doc "Select a planner workout and rationale under the existing Home CAS."
  def select_planned_workout(
        %Scope{user: %User{} = user},
        %HomeSelection{} = expected,
        id,
        rationale
      )
      when is_binary(rationale) and byte_size(rationale) <= 2400 do
    immediate_lifecycle_transaction(fn ->
      with {:ok, r} <- home_recommendation(user, expected),
           {:ok, plan} <- selectable_home_plan(user, r, id),
           :ok <- verify_stored_draft(plan),
           {:ok, changed} <- write_home_pointer(r, plan.id),
           {:ok, changed} <-
             changed |> Ecto.Changeset.change(rationale: rationale) |> Repo.update() do
        {:ok, HomeSelection.new(changed, plan)}
      end
    end)
  end

  @doc "Atomically finalizes and starts the reviewed Home selection."
  @spec start_home_workout(Scope.t(), HomeSelection.t(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def start_home_workout(%Scope{user: %User{} = user} = scope, %HomeSelection{} = expected, token) do
    immediate_lifecycle_transaction(fn ->
      with :ok <- valid_start_token(token),
           {:ok, _r} <- home_recommendation(user, expected),
           :new <-
             existing_start(user.id, token, :plan, expected.plan.id, expected.plan.content_hash),
           :ok <- no_other_started_session(user),
           {:ok, plan} <- verify_home_selection(scope, expected),
           {:ok, published} <- finalize_home_plan(user, expected, plan),
           {:ok, session} <- start_plan(scope, published.id, token) do
        finalized = if plan.state == :draft, do: published, else: nil
        {:ok, {session, finalized}}
      else
        {:existing, session} -> {:ok, {session, nil}}
        {:error, %Error{} = error} -> {:error, error}
      end
    end)
    |> case do
      {:ok, {value, _finalized}} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  @spec start_home_video(Scope.t(), HomeSelection.t(), pos_integer(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def start_home_video(
        %Scope{user: %User{} = user} = scope,
        %HomeSelection{} = expected,
        video_id,
        token
      ) do
    immediate_lifecycle_transaction(fn ->
      with :ok <- valid_start_token(token),
           {:ok, _r} <- home_recommendation(user, expected),
           {:ok, video} <- get_available_video_for_start(video_id),
           {:ok, _snapshot, hash} <- canonical_video_snapshot(video),
           :new <- existing_start(user.id, token, :video, video.id, hash),
           :ok <- no_other_started_session(user) do
        start_video(scope, video.id, token)
      else
        {:existing, session} -> {:ok, session}
        {:error, %Error{} = error} -> {:error, error}
      end
    end)
  end

  defp finalize_home_plan(_user, _expected, %{state: :published} = plan), do: {:ok, plan}

  defp finalize_home_plan(user, expected, %{state: :draft} = plan) do
    if expected.pending_draft_id == plan.id do
      with {:ok, _} <-
             accept_candidate(
               Scope.for_user(user),
               expected.recommendation_id,
               plan.id,
               expected.recommendation_selection
             ) do
        get_library_plan(Scope.for_user(user), plan.id)
      end
    else
      publish_unattached_draft(user, plan.id)
    end
  end

  defp valid_start_token(token) do
    case Ecto.UUID.cast(token) do
      {:ok, ^token} -> :ok
      _ -> {:error, Error.new(:invalid_start_token)}
    end
  end

  defp no_other_started_session(user) do
    if current_started_session(Scope.for_user(user)),
      do: {:error, Error.new(:session_in_progress)},
      else: :ok
  end

  defp existing_start(user_id, token, kind, id, hash) do
    case Repo.get_by(WorkoutSession, user_id: user_id, client_session_id: token) do
      nil ->
        :new

      session ->
        source_id =
          if session.source_kind == :plan,
            do: session.plan_id,
            else: session.workout_video_id

        if session.source_kind == kind and source_id == id and session.content_hash == hash,
          do: {:existing, session},
          else: {:error, Error.new(:start_token_source_mismatch)}
    end
  end

  @doc "Returns the exact current Home plan, rejecting stale identity or draft content."
  @spec verify_home_selection(Scope.t(), HomeSelection.t()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def verify_home_selection(%Scope{user: %User{} = user}, %HomeSelection{} = expected) do
    with {:ok, _r} <- home_recommendation(user, expected),
         {:ok, plan} <- home_plan(user, expected.plan.id),
         :ok <- compare_expected_draft_revision(plan, %{expected_revision: expected.plan}),
         :ok <- verify_stored_draft(plan) do
      {:ok, plan}
    end
  end

  def verify_plan_content(%WorkoutPlan{} = plan), do: verify_stored_draft(plan)

  @spec design_source(Scope.t(), pos_integer()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def design_source(%Scope{user: %User{} = user}, id), do: home_plan(user, id)

  defp home_recommendation(user, expected) do
    with %CoachRecommendation{} = r <-
           Repo.get_by(CoachRecommendation, id: expected.recommendation_id, user_id: user.id),
         {:ok, slot} <- Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second)),
         true <- r.slot_key == slot.slot_key and slot.home_state == :workout_needed,
         true <-
           r.home_workout_plan_id == expected.plan.id and
             r.home_revision == expected.home_revision do
      {:ok, r}
    else
      _ -> {:error, Error.new(:home_selection_changed)}
    end
  end

  defp home_plan(user, id) when is_integer(id) and id > 0 do
    case get_draft(Scope.for_user(user), id) do
      {:ok, plan} -> {:ok, plan}
      {:error, _} -> get_library_plan(Scope.for_user(user), id)
    end
  end

  defp home_plan(_user, _id), do: {:error, Error.new(:source_unavailable)}

  # Presentation validation is separate from Start's revision-first CAS checks.
  defp verified_home_plan(user, id) do
    with {:ok, plan} <- home_plan(user, id),
         :ok <- verify_stored_draft(plan) do
      {:ok, plan}
    end
  end

  defp verified_home_fallback do
    with {:ok, plan} <- built_in_fallback(),
         :ok <- verify_stored_draft(plan) do
      {:ok, plan}
    end
  end

  defp initial_home_plan(user, %{home_revision: 0} = r) do
    case verified_home_plan(user, r.pending_draft_id) do
      {:ok, %{state: :draft} = draft} ->
        {:ok, draft}

      _ ->
        case verified_home_plan(user, r.selected_workout_plan_id) do
          {:ok, %{state: :published} = plan} -> {:ok, plan}
          _ -> verified_home_fallback()
        end
    end
  end

  # A removed/invalid prior pin must not promote a late unrelated candidate.
  defp initial_home_plan(_user, _r), do: verified_home_fallback()

  defp selectable_home_plan(user, %{pending_draft_id: id}, id)
       when is_integer(id), do: get_draft(Scope.for_user(user), id)

  defp selectable_home_plan(user, _r, id), do: get_library_plan(Scope.for_user(user), id)

  defp write_home_pointer(r, id) do
    case r
         |> Ecto.Changeset.change(
           home_workout_plan_id: id,
           home_revision: r.home_revision + 1
         )
         |> Repo.update() do
      {:ok, changed} -> {:ok, changed}
      {:error, _} -> {:error, Error.new(:home_selection_changed)}
    end
  end

  @type recommendation_selection :: {:plan, pos_integer()} | {:video, pos_integer()}

  @doc "Ensures one fallback-backed recommendation for a deterministic user slot."
  @spec ensure_recommendation(Scope.t(), map()) ::
          {:ok, CoachRecommendation.t()} | {:error, Error.t()}
  def ensure_recommendation(%Scope{user: %User{id: user_id}}, attrs) when is_map(attrs) do
    immediate_lifecycle_transaction(fn ->
      with slot_key when is_binary(slot_key) and slot_key != "" <-
             Map.get(attrs, :slot_key) || Map.get(attrs, "slot_key"),
           %Date{} = slot_date <- Map.get(attrs, :slot_date) || Map.get(attrs, "slot_date"),
           {:ok, fallback} <- built_in_fallback() do
        rationale = Map.get(attrs, :rationale) || Map.get(attrs, "rationale")

        %CoachRecommendation{user_id: user_id}
        |> CoachRecommendation.changeset(%{
          slot_key: slot_key,
          slot_date: slot_date,
          rationale: rationale,
          selected_workout_plan_id: fallback.id,
          selected_workout_video_id: nil
        })
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:user_id, :slot_key]
        )

        case Repo.get_by(CoachRecommendation, user_id: user_id, slot_key: slot_key) do
          %CoachRecommendation{} = recommendation -> {:ok, recommendation}
          nil -> {:error, Error.new(:invalid_recommendation_selection)}
        end
      else
        {:error, %Error{} = error} -> {:error, error}
        _invalid -> {:error, Error.new(:invalid_recommendation_selection)}
      end
    end)
  end

  def ensure_recommendation(%Scope{}, _attrs),
    do: {:error, Error.new(:invalid_recommendation_selection)}

  @doc "Atomically accepts the exact pending draft against the caller's expected selection."
  @spec accept_candidate(
          Scope.t(),
          pos_integer(),
          pos_integer(),
          recommendation_selection()
        ) :: {:ok, CoachRecommendation.t()} | {:error, Error.t()}
  def accept_candidate(
        %Scope{user: %User{} = user} = scope,
        recommendation_id,
        draft_id,
        expected_selection
      ) do
    case accept_candidate_without_notification(
           user,
           recommendation_id,
           draft_id,
           expected_selection
         ) do
      {:ok, recommendation} ->
        case get_library_plan(scope, draft_id) do
          {:ok, _plan} -> :ok
          _ -> :ok
        end

        {:ok, recommendation}

      error ->
        error
    end
  end

  defp accept_candidate_without_notification(
         %User{id: user_id},
         recommendation_id,
         draft_id,
         expected_selection
       )
       when is_integer(recommendation_id) and recommendation_id > 0 and is_integer(draft_id) and
              draft_id > 0 do
    immediate_lifecycle_transaction(fn ->
      with {:ok, recommendation} <-
             current_candidate(user_id, recommendation_id, draft_id, expected_selection),
           {1, _rows} <- clear_current_candidate(recommendation, draft_id, expected_selection),
           %WorkoutPlan{user_id: ^user_id, state: :draft} = draft <-
             Repo.get(WorkoutPlan, draft_id),
           :ok <- verify_stored_draft(draft),
           {:ok, published} <-
             draft
             |> WorkoutPlan.publish_changeset(lifecycle_now())
             |> Repo.update()
             |> normalize_plan_write(),
           %CoachRecommendation{} = detached <-
             Repo.one(
               from(candidate in CoachRecommendation,
                 where:
                   candidate.id == ^recommendation_id and candidate.user_id == ^user_id and
                     is_nil(candidate.pending_draft_id)
               )
             ),
           {:ok, selected} <-
             detached
             |> CoachRecommendation.selection_changeset(%{
               selected_workout_plan_id: published.id,
               selected_workout_video_id: nil
             })
             |> Repo.update() do
        {:ok, selected}
      else
        {:error, %Error{} = error} ->
          {:error, error}

        {:error, %Ecto.Changeset{}} ->
          {:error, Error.new(:candidate_no_longer_current)}

        _stale ->
          {:error, Error.new(:candidate_no_longer_current)}
      end
    end)
  end

  defp accept_candidate_without_notification(
         %User{},
         _recommendation_id,
         _draft_id,
         _expected_selection
       ),
       do: {:error, Error.new(:candidate_no_longer_current)}

  @doc "Keeps a recommendation startable by selecting the built-in fallback when its source disappears."
  @spec ensure_recommendation_selection_available(Scope.t(), pos_integer()) ::
          {:ok, CoachRecommendation.t()} | {:error, Error.t()}
  def ensure_recommendation_selection_available(
        %Scope{user: %User{id: user_id} = user},
        recommendation_id
      )
      when is_integer(recommendation_id) and recommendation_id > 0 do
    immediate_lifecycle_transaction(fn ->
      case Repo.get_by(CoachRecommendation, id: recommendation_id, user_id: user_id) do
        %CoachRecommendation{} = recommendation ->
          if recommendation_selection_available?(user, recommendation) do
            {:ok, recommendation}
          else
            with {:ok, fallback} <- built_in_fallback(),
                 {:ok, available} <-
                   recommendation
                   |> CoachRecommendation.selection_changeset(%{
                     selected_workout_plan_id: fallback.id,
                     selected_workout_video_id: nil
                   })
                   |> Repo.update() do
              {:ok, available}
            else
              {:error, %Error{} = error} ->
                {:error, error}

              {:error, %Ecto.Changeset{}} ->
                {:error, Error.new(:invalid_recommendation_selection)}
            end
          end

        nil ->
          {:error, Error.new(:invalid_recommendation_selection)}
      end
    end)
  end

  def ensure_recommendation_selection_available(%Scope{}, _recommendation_id),
    do: {:error, Error.new(:invalid_recommendation_selection)}

  @spec get_library_plan(Scope.t(), pos_integer()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def get_library_plan(%Scope{user: %User{id: user_id}}, plan_id)
      when is_integer(plan_id) and plan_id > 0 do
    case Repo.get(WorkoutPlan, plan_id) do
      %WorkoutPlan{state: :published, user_id: ^user_id} = plan ->
        {:ok, plan}

      %WorkoutPlan{state: :published, user_id: nil, origin: :built_in} = plan ->
        {:ok, plan}

      %WorkoutPlan{state: :archived, user_id: ^user_id} ->
        {:error, Error.new(:archived_workout, %{plan_id: plan_id})}

      %WorkoutPlan{user_id: ^user_id} ->
        {:error, Error.new(:published_required, %{plan_id: plan_id})}

      _unavailable ->
        {:error, Error.new(:source_unavailable, %{plan_id: plan_id})}
    end
  end

  def get_library_plan(%Scope{}, plan_id),
    do: {:error, Error.new(:source_unavailable, %{plan_id: plan_id})}

  @spec get_draft(Scope.t(), pos_integer()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def get_draft(%Scope{user: %User{id: user_id}}, draft_id)
      when is_integer(draft_id) and draft_id > 0 do
    case Repo.get(WorkoutPlan, draft_id) do
      %WorkoutPlan{user_id: ^user_id, state: :draft} = draft ->
        {:ok, draft}

      %WorkoutPlan{user_id: ^user_id} ->
        {:error, Error.new(:draft_required, %{draft_id: draft_id})}

      %WorkoutPlan{} ->
        {:error, Error.new(:draft_not_owned, %{draft_id: draft_id})}

      nil ->
        {:error, Error.new(:draft_not_found, %{draft_id: draft_id})}
    end
  end

  def get_draft(%Scope{}, draft_id),
    do: {:error, Error.new(:draft_not_found, %{draft_id: draft_id})}

  @spec archive_plan(Scope.t(), pos_integer()) ::
          {:ok, WorkoutPlan.t()} | {:error, Error.t()}
  def archive_plan(%Scope{user: %User{} = user}, plan_id)
      when is_integer(plan_id) and plan_id > 0 do
    immediate_lifecycle_transaction(fn -> archive_owned_plan(user, plan_id) end)
  end

  def archive_plan(%Scope{}, plan_id),
    do: {:error, Error.new(:source_unavailable, %{plan_id: plan_id})}

  @draft_revision_fields [
    :id,
    :user_id,
    :name,
    :origin,
    :state,
    :request_text,
    :definition_json,
    :program_json,
    :content_hash,
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :published_at,
    :archived_at,
    :inserted_at,
    :updated_at
  ]

  @definition_keys ~w[
    version name burpee_type target_duration_sec target_reps pacing_style rationale events
  ]
  @definition_atom_keys [
    :version,
    :name,
    :burpee_type,
    :target_duration_sec,
    :target_reps,
    :pacing_style,
    :rationale,
    :events
  ]

  defp canonical_draft_content(attrs) do
    with {:ok, definition_attrs} <- draft_definition(attrs),
         {:ok, definition} <- WorkoutDefinition.new(definition_attrs),
         {:ok, program} <- PlanCompiler.compile(definition) do
      {:ok,
       %{
         name: definition.name,
         request_text: draft_request_text(attrs),
         definition_json: WorkoutDefinition.canonical_map(definition),
         program_json: ProgramHash.canonical_map(program),
         content_hash: ProgramHash.hash(program),
         burpee_type: definition.burpee_type,
         target_reps: definition.target_reps,
         target_duration_sec: definition.target_duration_sec
       }}
    end
  end

  defp draft_definition(attrs) do
    definition =
      Map.get(attrs, :definition) || Map.get(attrs, "definition") ||
        Map.get(attrs, :definition_json) || Map.get(attrs, "definition_json")

    cond do
      is_map(definition) ->
        {:ok, definition}

      Map.has_key?(attrs, :version) or Map.has_key?(attrs, "version") ->
        {:ok, Map.take(attrs, @definition_keys ++ @definition_atom_keys)}

      true ->
        {:error, Error.new(:invalid_workout_definition, %{field: :definition})}
    end
  end

  defp draft_request_text(attrs) do
    Map.get(attrs, :request_text) || Map.get(attrs, "request_text")
  end

  defp compare_expected_draft_revision(draft, attrs) do
    case Map.fetch(attrs, :expected_revision) do
      :error ->
        :ok

      {:ok, %WorkoutPlan{} = expected} ->
        if Map.take(draft, @draft_revision_fields) == Map.take(expected, @draft_revision_fields) do
          :ok
        else
          {:error, Error.new(:draft_stale)}
        end

      {:ok, _invalid} ->
        {:error, Error.new(:draft_stale)}
    end
  end

  defp normalize_plan_write({:ok, %WorkoutPlan{} = plan}), do: {:ok, plan}

  defp normalize_plan_write({:error, %Ecto.Changeset{} = changeset}) do
    {:error,
     Error.new(:infeasible_workout_definition, %{
       errors: Enum.map(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
     })}
  end

  defp get_mutable_draft(%User{} = user, draft_id) do
    case get_draft(Scope.for_user(user), draft_id) do
      {:error, %Error{code: :draft_required}} ->
        {:error, Error.new(:workout_immutable, %{draft_id: draft_id})}

      result ->
        result
    end
  end

  defp publish_unattached_draft(%User{} = user, draft_id) do
    with {:ok, draft} <- get_mutable_draft(user, draft_id),
         false <- candidate_attached?(draft.id),
         :ok <- verify_stored_draft(draft),
         {:ok, published} <-
           draft
           |> WorkoutPlan.publish_changeset(lifecycle_now())
           |> Repo.update()
           |> normalize_plan_write() do
      {:ok, published}
    else
      true -> {:error, Error.new(:candidate_attached, %{draft_id: draft_id})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp verify_stored_draft(%WorkoutPlan{} = draft) do
    with {:ok, expected} <-
           canonical_draft_content(%{
             definition: draft.definition_json,
             request_text: draft.request_text
           }) do
      exact? =
        draft.name == expected.name and draft.definition_json == expected.definition_json and
          draft.program_json == expected.program_json and
          draft.content_hash == expected.content_hash and
          draft.burpee_type == expected.burpee_type and
          draft.target_reps == expected.target_reps and
          draft.target_duration_sec == expected.target_duration_sec

      if exact? do
        :ok
      else
        {:error,
         Error.new(:infeasible_workout_definition, %{
           draft_id: draft.id,
           reason: :stored_program_mismatch
         })}
      end
    end
  end

  defp archive_owned_plan(%User{id: user_id}, plan_id) do
    with {:ok, plan} <- published_plan_for_archive(user_id, plan_id),
         {:ok, fallback} <- built_in_fallback(),
         {:ok, archived} <-
           plan
           |> WorkoutPlan.archive_changeset(lifecycle_now())
           |> Repo.update()
           |> normalize_plan_write() do
      now = lifecycle_now()

      Repo.update_all(
        from(recommendation in CoachRecommendation,
          where: recommendation.selected_workout_plan_id == ^plan.id
        ),
        set: [
          selected_workout_plan_id: fallback.id,
          selected_workout_video_id: nil,
          updated_at: now
        ]
      )

      {:ok, archived}
    end
  end

  defp published_plan_for_archive(user_id, plan_id) do
    case Repo.get(WorkoutPlan, plan_id) do
      %WorkoutPlan{user_id: ^user_id, state: :published} = plan ->
        {:ok, plan}

      %WorkoutPlan{user_id: ^user_id, state: :archived} ->
        {:error, Error.new(:archived_workout, %{plan_id: plan_id})}

      %WorkoutPlan{user_id: ^user_id} ->
        {:error, Error.new(:published_required, %{plan_id: plan_id})}

      _unavailable ->
        {:error, Error.new(:source_unavailable, %{plan_id: plan_id})}
    end
  end

  defp current_candidate(user_id, recommendation_id, draft_id, expected_selection) do
    case Repo.get_by(CoachRecommendation, id: recommendation_id, user_id: user_id) do
      %CoachRecommendation{pending_draft_id: ^draft_id} = recommendation ->
        if current_recommendation_selection(recommendation) == expected_selection do
          {:ok, recommendation}
        else
          {:error, Error.new(:recommendation_selection_changed)}
        end

      _stale ->
        {:error, Error.new(:candidate_no_longer_current)}
    end
  end

  defp clear_current_candidate(recommendation, draft_id, expected_selection) do
    query =
      from(candidate in CoachRecommendation,
        where:
          candidate.id == ^recommendation.id and candidate.user_id == ^recommendation.user_id and
            candidate.pending_draft_id == ^draft_id
      )
      |> constrain_expected_selection(expected_selection)

    Repo.update_all(query, set: [pending_draft_id: nil, updated_at: lifecycle_now()])
  end

  defp constrain_expected_selection(query, {:plan, plan_id})
       when is_integer(plan_id) and plan_id > 0 do
    from(candidate in query,
      where:
        candidate.selected_workout_plan_id == ^plan_id and
          is_nil(candidate.selected_workout_video_id)
    )
  end

  defp constrain_expected_selection(query, {:video, video_id})
       when is_integer(video_id) and video_id > 0 do
    from(candidate in query,
      where:
        candidate.selected_workout_video_id == ^video_id and
          is_nil(candidate.selected_workout_plan_id)
    )
  end

  defp constrain_expected_selection(query, _invalid), do: where(query, [candidate], false)

  defp current_recommendation_selection(%CoachRecommendation{
         selected_workout_plan_id: plan_id,
         selected_workout_video_id: nil
       })
       when is_integer(plan_id) and plan_id > 0,
       do: {:plan, plan_id}

  defp current_recommendation_selection(%CoachRecommendation{
         selected_workout_plan_id: nil,
         selected_workout_video_id: video_id
       })
       when is_integer(video_id) and video_id > 0,
       do: {:video, video_id}

  defp current_recommendation_selection(_invalid), do: :invalid

  defp recommendation_selection_available?(
         %User{} = user,
         %CoachRecommendation{} = recommendation
       ) do
    case current_recommendation_selection(recommendation) do
      {:plan, plan_id} ->
        match?({:ok, %WorkoutPlan{}}, get_library_plan(Scope.for_user(user), plan_id))

      {:video, _video_id} ->
        false

      :invalid ->
        false
    end
  end

  defp built_in_fallback do
    case Repo.one(
           from(plan in WorkoutPlan,
             where:
               is_nil(plan.user_id) and plan.origin == :built_in and plan.state == :published,
             order_by: [asc: plan.id],
             limit: 1
           )
         ) do
      %WorkoutPlan{} = fallback -> {:ok, fallback}
      nil -> {:error, Error.new(:source_unavailable, %{source: :built_in_fallback})}
    end
  end

  defp candidate_attached?(draft_id) do
    Repo.exists?(
      from(recommendation in CoachRecommendation,
        where: recommendation.pending_draft_id == ^draft_id
      )
    )
  end

  defp immediate_lifecycle_transaction(fun) when is_function(fun, 0) do
    case Repo.immediate_transaction(fn ->
           case fun.() do
             {:ok, value} -> value
             :ok -> :ok
             {:error, %Error{} = error} -> Repo.rollback(error)
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, value} -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp lifecycle_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp field_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field_value(_value, _key), do: nil

  # ---------------------------------------------------------------------------
  # Pose capture
  # ---------------------------------------------------------------------------

  @doc """
  Ingest a deferred pose-trace batch for an already-saved, user-scoped session.

  Chunk indexes are idempotent per run. The run is completed only when the
  caller marks the final acknowledged batch complete.
  """
  @spec ingest_pose_trace_batch(
          Scope.t(),
          pos_integer(),
          Ecto.UUID.t(),
          [map()],
          boolean()
        ) ::
          {:ok, %{accepted_indexes: [non_neg_integer()], complete: boolean()}}
          | {:error, Ecto.Changeset.t() | :invalid_batch | :not_found}
  def ingest_pose_trace_batch(
        %Scope{user: %User{id: user_id}},
        session_id,
        client_session_id,
        chunks,
        complete?
      )
      when is_integer(session_id) and session_id > 0 and is_binary(client_session_id) and
             is_list(chunks) and is_boolean(complete?) do
    Multi.new()
    |> Multi.run(:session, fn repo, _changes ->
      case repo.get_by(WorkoutSession,
             id: session_id,
             user_id: user_id,
             client_session_id: client_session_id,
             state: :completed
           ) do
        %WorkoutSession{state: :completed} = session -> {:ok, session}
        nil -> {:error, :not_found}
      end
    end)
    |> Multi.run(:run, fn repo, %{session: session} ->
      get_or_insert_deferred_pose_run(repo, user_id, session)
    end)
    |> Multi.run(:chunks, fn repo, %{run: run} ->
      insert_deferred_pose_chunks(repo, run, chunks)
    end)
    |> Multi.run(:completion, fn repo, %{run: run, session: session} ->
      complete_deferred_pose_run(repo, run, session, complete?)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{chunks: accepted_indexes, completion: run}} ->
        {:ok, %{accepted_indexes: accepted_indexes, complete: run.status == :completed}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def ingest_pose_trace_batch(
        %Scope{},
        _session_id,
        _client_session_id,
        _chunks,
        _complete?
      ),
      do: {:error, :invalid_batch}

  defp get_or_insert_deferred_pose_run(repo, user_id, session) do
    case repo.get_by(PoseCaptureRun,
           workout_session_id: session.id,
           user_id: user_id
         ) do
      %PoseCaptureRun{} = run ->
        {:ok, run}

      nil ->
        changeset =
          %PoseCaptureRun{
            user_id: user_id,
            workout_session_id: session.id,
            status: :active
          }
          |> PoseCaptureRun.start_changeset(%{"started_at" => DateTime.utc_now(:second)})

        case repo.insert(changeset) do
          {:ok, run} ->
            {:ok, run}

          {:error, changeset} ->
            case repo.get_by(PoseCaptureRun,
                   workout_session_id: session.id,
                   user_id: user_id
                 ) do
              %PoseCaptureRun{} = run -> {:ok, run}
              nil -> {:error, changeset}
            end
        end
    end
  end

  defp insert_deferred_pose_chunks(
         repo,
         %PoseCaptureRun{status: :completed} = run,
         chunks
       ) do
    with {:ok, prepared} <- prepare_deferred_pose_chunks(run, chunks) do
      indexes = prepared |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      persisted_by_index =
        if indexes == [] do
          %{}
        else
          repo.all(
            from(chunk in PoseTraceChunk,
              where: chunk.pose_capture_run_id == ^run.id and chunk.chunk_index in ^indexes
            )
          )
          |> Map.new(&{&1.chunk_index, &1})
        end

      if Enum.all?(prepared, fn {index, changeset} ->
           case Map.get(persisted_by_index, index) do
             %PoseTraceChunk{} = persisted -> pose_chunk_matches?(persisted, changeset)
             nil -> false
           end
         end) do
        {:ok, indexes}
      else
        {:error, :invalid_batch}
      end
    end
  end

  defp insert_deferred_pose_chunks(repo, %PoseCaptureRun{status: :active} = run, chunks) do
    with {:ok, prepared} <- prepare_deferred_pose_chunks(run, chunks) do
      Enum.reduce_while(prepared, {:ok, []}, fn {index, changeset}, {:ok, indexes} ->
        case repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:pose_capture_run_id, :chunk_index]
             ) do
          {:ok, _chunk} ->
            case repo.get_by(PoseTraceChunk,
                   pose_capture_run_id: run.id,
                   chunk_index: index
                 ) do
              %PoseTraceChunk{} = persisted ->
                if pose_chunk_matches?(persisted, changeset) do
                  {:cont, {:ok, [index | indexes]}}
                else
                  {:halt, {:error, :invalid_batch}}
                end

              nil ->
                {:halt, {:error, :invalid_batch}}
            end

          {:error, changeset} ->
            {:halt, {:error, changeset}}
        end
      end)
      |> case do
        {:ok, indexes} -> {:ok, indexes |> Enum.reverse() |> Enum.uniq() |> Enum.sort()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp pose_chunk_matches?(%PoseTraceChunk{} = persisted, changeset) do
    Enum.all?(@pose_chunk_identity_fields, fn field ->
      Map.fetch!(persisted, field) == Ecto.Changeset.get_field(changeset, field)
    end)
  end

  defp prepare_deferred_pose_chunks(run, chunks) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, prepared} ->
      changeset = deferred_pose_chunk_changeset(run, attrs)

      if changeset.valid? do
        index = Ecto.Changeset.get_field(changeset, :chunk_index)
        {:cont, {:ok, [{index, changeset} | prepared]}}
      else
        {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp deferred_pose_chunk_changeset(run, attrs) when is_map(attrs) do
    payload = chunk_value(attrs, "payload")

    normalized = %{
      "segment" => chunk_value(attrs, "segment"),
      "chunk_index" => chunk_value(attrs, "chunk_index"),
      "started_at_ms" => chunk_value(attrs, "started_at_ms"),
      "ended_at_ms" => chunk_value(attrs, "ended_at_ms"),
      "sample_count" => chunk_value(attrs, "sample_count"),
      "payload_json" => Jason.encode!(payload)
    }

    %PoseTraceChunk{pose_capture_run_id: run.id}
    |> PoseTraceChunk.changeset(normalized)
  end

  defp deferred_pose_chunk_changeset(run, _attrs) do
    %PoseTraceChunk{pose_capture_run_id: run.id}
    |> PoseTraceChunk.changeset(%{})
  end

  defp chunk_value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))
  end

  defp complete_deferred_pose_run(
         _repo,
         %PoseCaptureRun{status: :completed} = run,
         _session,
         _complete?
       ),
       do: {:ok, run}

  defp complete_deferred_pose_run(_repo, run, _session, false), do: {:ok, run}

  defp complete_deferred_pose_run(repo, run, session, true) do
    run
    |> PoseCaptureRun.complete_changeset(%{
      "workout_session_id" => session.id,
      "completed_at" => DateTime.utc_now(:second)
    })
    |> repo.update()
  end

  @spec start_plan(Scope.t(), pos_integer(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def start_plan(%Scope{user: %User{id: user_id}}, plan_id, client_session_id)
      when is_integer(plan_id) and plan_id > 0 and is_binary(client_session_id) do
    start_session(user_id, client_session_id, fn ->
      with {:ok, plan} <- get_visible_plan_for_start(user_id, plan_id),
           :ok <- startable_plan(plan) do
        {:ok,
         %WorkoutSession{
           user_id: user_id,
           state: :started,
           source_kind: :plan,
           plan_id: plan.id,
           display_name_snapshot: plan.name,
           workout_type_snapshot: plan.burpee_type,
           burpee_type: plan.burpee_type,
           burpee_count_planned: plan.target_reps,
           duration_sec_planned: plan.target_duration_sec,
           program_snapshot: plan.program_json,
           content_hash: plan.content_hash,
           client_session_id: client_session_id,
           started_at: session_now()
         }}
      end
    end)
  end

  def start_plan(%Scope{}, plan_id, _client_session_id),
    do: {:error, Error.new(:source_unavailable, %{plan_id: plan_id})}

  @spec start_video(Scope.t(), pos_integer(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def start_video(%Scope{user: %User{id: user_id}}, video_id, client_session_id)
      when is_integer(video_id) and video_id > 0 and is_binary(client_session_id) do
    start_session(user_id, client_session_id, fn ->
      with {:ok, video} <- get_available_video_for_start(video_id),
           {:ok, snapshot, content_hash} <- canonical_video_snapshot(video) do
        {:ok,
         %WorkoutSession{
           user_id: user_id,
           state: :started,
           source_kind: :video,
           workout_video_id: video.id,
           display_name_snapshot: video.name,
           workout_type_snapshot: video.burpee_type,
           burpee_type: video.burpee_type,
           burpee_count_planned: video.burpee_count,
           duration_sec_planned: video.duration_sec,
           video_snapshot: snapshot,
           content_hash: content_hash,
           client_session_id: client_session_id,
           started_at: session_now()
         }}
      else
        {:error, %Error{code: :invalid_video_snapshot}} ->
          {:error, Error.new(:source_unavailable, %{video_id: video_id})}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  def start_video(%Scope{}, video_id, _client_session_id),
    do: {:error, Error.new(:source_unavailable, %{video_id: video_id})}

  defp canonical_video_snapshot(video) do
    ProgramHash.video_snapshot(%{
      "name" => video.name,
      "filename" => video.filename,
      "type" => Atom.to_string(video.burpee_type),
      "duration" => video.duration_sec,
      "count" => video.burpee_count,
      "format" => Atom.to_string(video.format)
    })
  end

  defp start_session(user_id, client_session_id, source) when is_function(source, 0) do
    Repo.immediate_transaction(fn ->
      with :ok <- valid_start_token(client_session_id),
           {:ok, proposed} <- source.() do
        id =
          if proposed.source_kind == :plan,
            do: proposed.plan_id,
            else: proposed.workout_video_id

        case existing_start(
               user_id,
               client_session_id,
               proposed.source_kind,
               id,
               proposed.content_hash
             ) do
          {:existing, session} ->
            session

          :new ->
            case proposed |> WorkoutSession.start_changeset() |> Repo.insert() do
              {:ok, inserted} -> inserted
              {:error, changeset} -> Repo.rollback(changeset)
            end

          {:error, error} ->
            Repo.rollback(error)
        end
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, %WorkoutSession{} = session} ->
        {:ok, session}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, Error.new(:source_unavailable, %{errors: changeset.errors})}
    end
  end

  defp get_visible_plan_for_start(user_id, plan_id) do
    case Repo.one(
           from(plan in WorkoutPlan,
             where:
               plan.id == ^plan_id and
                 (plan.user_id == ^user_id or
                    (is_nil(plan.user_id) and plan.origin == :built_in))
           )
         ) do
      %WorkoutPlan{} = plan -> {:ok, plan}
      nil -> {:error, Error.new(:source_unavailable, %{plan_id: plan_id})}
    end
  end

  defp startable_plan(%WorkoutPlan{state: :published}), do: :ok

  defp startable_plan(%WorkoutPlan{state: :draft, id: id}),
    do: {:error, Error.new(:draft_cannot_start, %{plan_id: id})}

  defp startable_plan(%WorkoutPlan{state: :archived, id: id}),
    do: {:error, Error.new(:archived_workout, %{plan_id: id})}

  defp get_available_video_for_start(video_id) do
    case Repo.get(WorkoutVideo, video_id) do
      %WorkoutVideo{available: true, format: :follow_along} = video -> {:ok, video}
      _missing_or_unavailable -> {:error, Error.new(:source_unavailable, %{video_id: video_id})}
    end
  end

  @spec current_started_session(Scope.t()) :: WorkoutSession.t() | nil
  def current_started_session(%Scope{user: %User{id: user_id}}) do
    Repo.one(
      from(session in WorkoutSession,
        where: session.user_id == ^user_id and session.state == :started,
        order_by: [desc: session.started_at, desc: session.id],
        limit: 1
      )
    )
  end

  @spec resume_session(Scope.t(), pos_integer()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t()}
  def resume_session(%Scope{user: %User{id: user_id}}, session_id)
      when is_integer(session_id) and session_id > 0 do
    case Repo.get_by(WorkoutSession, id: session_id, user_id: user_id) do
      %WorkoutSession{state: :started} = session ->
        {:ok, session}

      %WorkoutSession{state: :completed} ->
        {:error, Error.new(:session_already_completed, %{session_id: session_id})}

      nil ->
        {:error, Error.new(:session_not_owned, %{session_id: session_id})}
    end
  end

  def resume_session(%Scope{}, session_id),
    do: {:error, Error.new(:session_not_owned, %{session_id: session_id})}

  @spec complete_session(Scope.t(), pos_integer(), map(), term()) ::
          {:ok, WorkoutSession.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def complete_session(
        %Scope{user: %User{id: user_id} = user} = scope,
        session_id,
        attrs,
        capture
      )
      when is_integer(session_id) and session_id > 0 and is_map(attrs) do
    Repo.immediate_transaction(fn ->
      case Repo.get_by(WorkoutSession, id: session_id, user_id: user_id) do
        %WorkoutSession{state: :completed} ->
          Repo.rollback(Error.new(:session_already_completed, %{session_id: session_id}))

        %WorkoutSession{state: :started} = session ->
          changeset =
            session
            |> WorkoutSession.completion_changeset(attrs, session_now())
            |> apply_session_capture(capture)
            |> maybe_with_snapshot_deviation(session)
            |> with_derived_session_fields(user_id, user.timezone)

          persist_completed_session(user, changeset, &Repo.update/1)

        nil ->
          Repo.rollback(Error.new(:session_not_owned, %{session_id: session_id}))
      end
    end)
    |> case do
      {:ok, %WorkoutSession{} = session} ->
        :ok = BurpeeTrainer.Coach.PlanNextWorkoutJob.enqueue(scope)
        {:ok, session}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def complete_session(%Scope{}, session_id, _attrs, _capture),
    do: {:error, Error.new(:session_not_owned, %{session_id: session_id})}

  defp persist_completed_session(%User{} = user, changeset, persist)
       when is_function(persist, 1) do
    {changeset, achieved_goal} = attribute_achieved_goal(user, changeset)

    case persist.(changeset) do
      {:ok, %WorkoutSession{} = completed} ->
        case mark_goal_achieved(achieved_goal) do
          :ok -> completed
          {:error, %Ecto.Changeset{} = goal_changeset} -> Repo.rollback(goal_changeset)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp attribute_achieved_goal(%User{} = user, changeset) do
    if changeset.valid? do
      burpee_type = Ecto.Changeset.get_field(changeset, :burpee_type)
      count = Ecto.Changeset.get_field(changeset, :burpee_count_actual)
      duration = Ecto.Changeset.get_field(changeset, :duration_sec_actual)
      completed_at = Ecto.Changeset.get_field(changeset, :completed_at)
      goal = Goals.get_active_goal(Scope.for_user(user), burpee_type)

      if goal && goal_achieved_by_completion?(goal, count, duration, completed_at, user.timezone) do
        {Ecto.Changeset.put_change(changeset, :goal_id, goal.id), goal}
      else
        {changeset, nil}
      end
    else
      {changeset, nil}
    end
  end

  defp goal_achieved_by_completion?(
         %Goal{burpee_count_target: target, date_baseline: baseline},
         count,
         duration,
         %DateTime{} = completed_at,
         timezone
       )
       when is_integer(count) and count > 0 and is_integer(duration) and duration >= 1190 and
              duration <= 1210 do
    with {:ok, completed_date} <- UserTime.local_date(completed_at, timezone) do
      Date.compare(completed_date, baseline) != :lt and
        round(count / duration * 1200.0) >= target
    else
      {:error, _reason} -> false
    end
  end

  defp goal_achieved_by_completion?(%Goal{}, _count, _duration, _completed_at, _timezone),
    do: false

  defp mark_goal_achieved(nil), do: :ok

  defp mark_goal_achieved(%Goal{} = goal) do
    case Goals.mark_achieved(goal) do
      {:ok, %Goal{}} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp apply_session_capture(changeset, :timed) do
    Ecto.Changeset.change(changeset,
      capture_mode: :timed,
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil
    )
  end

  defp apply_session_capture(changeset, :logged) do
    Ecto.Changeset.change(changeset,
      capture_mode: :logged,
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil
    )
  end

  defp apply_session_capture(changeset, :manual_correction),
    do: apply_tracked_session_mode(changeset, :manual_correction)

  defp apply_session_capture(changeset, {:trusted, cadence, target_pace}),
    do: apply_tracked_session_mode(changeset, {:trusted, cadence, target_pace})

  defp apply_session_capture(changeset, %{mode: :tracked} = capture) do
    apply_session_capture(
      changeset,
      {:trusted, Map.get(capture, :cadence_ms, []), Map.get(capture, :target_pace_sec)}
    )
  end

  defp apply_session_capture(changeset, %{mode: :timed}),
    do: apply_session_capture(changeset, :timed)

  defp apply_session_capture(changeset, %{mode: :logged}),
    do: apply_session_capture(changeset, :logged)

  defp apply_session_capture(changeset, _invalid) do
    Ecto.Changeset.add_error(changeset, :capture_mode, "is invalid")
  end

  defp maybe_with_snapshot_deviation(changeset, %WorkoutSession{
         source_kind: :plan,
         program_snapshot: program_snapshot
       })
       when is_map(program_snapshot) do
    with_program_deviation_fields(changeset, program_snapshot)
  end

  defp maybe_with_snapshot_deviation(changeset, %WorkoutSession{}), do: changeset

  defp session_now, do: DateTime.utc_now(:second)

  @doc """
  List sessions for a user, most recent first. Optional `burpee_type`
  filter.
  """
  @spec list_sessions(Scope.t()) :: [WorkoutSession.t()]
  def list_sessions(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from(session in WorkoutSession,
        where: session.user_id == ^user_id and session.state == :completed,
        order_by: [desc: session.completed_at, desc: session.id]
      )
    )
  end

  @spec list_sessions(Scope.t(), atom) :: [WorkoutSession.t()]
  def list_sessions(%Scope{user: %User{id: user_id}}, burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from(session in WorkoutSession,
        where:
          session.user_id == ^user_id and session.state == :completed and
            session.burpee_type == ^burpee_type,
        order_by: [desc: session.completed_at, desc: session.id]
      )
    )
  end

  @doc "Returns the latest 16 non-warmup sessions used by coach memory and generation."
  @spec list_recent_training_sessions(Scope.t()) :: [WorkoutSession.t()]
  def list_recent_training_sessions(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from(session in WorkoutSession,
        where:
          session.user_id == ^user_id and session.state == :completed and
            (is_nil(session.tags) or session.tags != "warmup"),
        order_by: [desc: session.completed_at, desc: session.id],
        limit: 16
      )
    )
    |> preload_session_execution_refs()
  end

  defp preload_session_execution_refs(sessions) when is_list(sessions), do: sessions

  @doc """
  Return the newest persisted coach recommendation for a user.
  """
  @spec current_coach_recommendation(Scope.t()) :: CoachRecommendation.t() | nil
  def current_coach_recommendation(%Scope{user: %User{id: user_id}}) do
    Repo.one(
      from(recommendation in CoachRecommendation,
        where: recommendation.user_id == ^user_id,
        order_by: [desc: recommendation.inserted_at, desc: recommendation.id],
        limit: 1,
        preload: [:selected_workout_plan, :selected_workout_video, :pending_draft]
      )
    )
  end

  @doc """
  Return per-ISO-week training minutes for a user, excluding warmup sessions.
  Weeks are Mon–Sun. Result is sorted descending by `week_start`.
  """
  @spec weekly_minutes(Scope.t()) :: [%{week_start: Date.t(), minutes: float, met_goal: bool}]
  def weekly_minutes(%Scope{user: %User{id: user_id, timezone: timezone}}) do
    sessions =
      Repo.all(
        from(s in WorkoutSession,
          where:
            s.user_id == ^user_id and s.state == :completed and
              (is_nil(s.tags) or s.tags != "warmup"),
          select: %{completed_at: s.completed_at, duration_sec_actual: s.duration_sec_actual}
        )
      )

    sessions
    |> Enum.group_by(fn %{completed_at: completed_at} ->
      {:ok, local_date} = UserTime.local_date(completed_at, timezone)
      Date.beginning_of_week(local_date, :monday)
    end)
    |> Enum.map(fn {week_start, rows} ->
      minutes = Enum.sum_by(rows, & &1.duration_sec_actual) / 60.0
      %{week_start: week_start, minutes: minutes, met_goal: minutes >= 79.0}
    end)
    |> Enum.sort_by(& &1.week_start, {:desc, Date})
  end

  @doc """
  Cursor-based paginated completed sessions. Returns `{sessions, has_more?}`.

  Pass `before: {completed_at, id}` using the final row from the prior page.
  The compound cursor matches the descending `completed_at, id` ordering, so
  sessions sharing a completion timestamp are neither skipped nor repeated.
  Malformed cursors return `{:error, :invalid_cursor}`.
  """
  @spec list_sessions_page(Scope.t(), pos_integer()) ::
          {[WorkoutSession.t()], boolean()} | {:error, :invalid_cursor}
  @spec list_sessions_page(Scope.t(), pos_integer(), keyword()) ::
          {[WorkoutSession.t()], boolean()} | {:error, :invalid_cursor}
  def list_sessions_page(%Scope{user: %User{id: user_id}}, limit, opts \\ []) do
    query =
      from(s in WorkoutSession,
        where: s.user_id == ^user_id and s.state == :completed,
        order_by: [desc: s.completed_at, desc: s.id],
        limit: ^(limit + 1),
        preload: [:plan, :goal]
      )

    case Keyword.fetch(opts, :before) do
      :error ->
        session_page(query, limit)

      {:ok, {%DateTime{} = completed_at, id}} when is_integer(id) and id > 0 ->
        query
        |> where(
          [s],
          s.completed_at < ^completed_at or
            (s.completed_at == ^completed_at and s.id < ^id)
        )
        |> session_page(limit)

      {:ok, _malformed_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  defp session_page(query, limit) do
    rows = Repo.all(query)
    has_more = length(rows) > limit
    {Enum.take(rows, limit), has_more}
  end

  @doc """
  All sessions for a user + burpee type suitable for progress charting:
  burpee_count_actual > 0 and duration_sec_actual > 0, ordered oldest first.
  """
  @spec get_session(Scope.t(), integer) :: WorkoutSession.t() | nil
  def get_session(%Scope{user: %User{id: user_id}}, id) when is_integer(id) and id > 0 do
    Repo.one(
      from(s in WorkoutSession,
        where: s.user_id == ^user_id and s.id == ^id,
        preload: [:plan, :goal]
      )
    )
  end

  def get_session(%Scope{}, _invalid_id), do: nil

  @spec list_sessions_for_chart(Scope.t(), atom) :: [WorkoutSession.t()]
  def list_sessions_for_chart(%Scope{user: %User{id: user_id}}, burpee_type)
      when is_atom(burpee_type) do
    Repo.all(
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and s.state == :completed and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual > 0,
        order_by: [asc: s.completed_at, asc: s.id]
      )
    )
  end

  defp apply_tracked_session_mode(changeset, :manual_correction) do
    Ecto.Changeset.change(changeset,
      capture_mode: :tracked,
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil
    )
  end

  defp apply_tracked_session_mode(changeset, {:trusted, cadence, target_pace}) do
    consistency = if valid_cadence_values?(cadence), do: PaceConsistency.score(cadence)

    changeset
    |> validate_tracked_capture(cadence)
    |> Ecto.Changeset.change(
      capture_mode: :tracked,
      cadence_ms: Jason.encode!(cadence),
      target_pace_sec: parse_optional_float(target_pace),
      pace_consistency: consistency
    )
  end

  @doc """
  Delete a completed session for a user.

  Linked tracked capture runs are deleted first so stored pose traces are not
  left behind after removing an accidental saved session.
  """
  @spec delete_session(Scope.t(), integer() | WorkoutSession.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def delete_session(%Scope{user: %User{id: user_id}} = scope, session_id)
      when is_integer(session_id) do
    case Repo.get_by(WorkoutSession, id: session_id, user_id: user_id) do
      nil -> {:error, :not_found}
      session -> delete_session(scope, session)
    end
  end

  def delete_session(
        %Scope{user: %User{id: user_id}},
        %WorkoutSession{user_id: user_id} = session
      ) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(
          from(run in PoseCaptureRun,
            where: run.user_id == ^user_id and run.workout_session_id == ^session.id
          )
        )

        case Repo.delete(session) do
          {:ok, deleted} -> deleted
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, deleted} -> {:ok, deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_session(%Scope{}, %WorkoutSession{}), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Gamification — push-up score, personal bests, milestone detection
  # ---------------------------------------------------------------------------

  @doc """
  Presents milestones for a completed session and updates aggregate bests.

  Goal attribution is read-only here: completion already persisted `goal_id`
  and the achieved goal atomically with the session transition.
  """
  @spec session_milestones(Scope.t(), WorkoutSession.t()) :: [map]
  @spec session_milestones(Scope.t(), WorkoutSession.t(), Date.t() | nil) :: [map]
  def session_milestones(
        %Scope{user: %User{id: user_id, timezone: timezone}},
        %WorkoutSession{state: :completed, completed_at: %DateTime{} = completed_at} = session,
        today \\ nil
      ) do
    {:ok, completed_date} = UserTime.local_date(completed_at, timezone)
    today = today || completed_date

    before_sessions =
      user_id
      |> scoring_sessions_before(completed_at)
      |> localize_scoring_sessions(timezone)

    after_sessions =
      before_sessions ++
        localize_scoring_sessions([scoring_session_map(session)], timezone)

    week_date = completed_date
    stats = gamification_stats_before(before_sessions)

    session_pushups = Scoring.session_pushups(session_map(session))
    week_after = Scoring.week_pushups(after_sessions, week_date)
    week_before = Scoring.week_pushups(before_sessions, week_date)
    lifetime_after = Scoring.total_pushups(after_sessions)

    {pace, pace_qualifies?} = session_pace(session)

    input = %{
      level_before: Levels.current_level(before_sessions, today),
      level_after: Levels.current_level(after_sessions, today),
      week_pushups_before: week_before,
      week_pushups_after: week_after,
      best_week_pushups_before: stats.best_week_pushups,
      session_pushups: session_pushups,
      best_session_pushups_before: stats.best_session_pushups,
      session_pace: pace,
      session_qualifies_pace?: pace_qualifies?,
      best_pace_before: stats.best_pace_sec_per_burpee,
      lifetime_after: lifetime_after,
      lifetime_milestone_before: stats.lifetime_pushup_milestone,
      balanced_before?: Scoring.balanced_week?(week_sessions(before_sessions, week_date)),
      balanced_after?: Scoring.balanced_week?(week_sessions(after_sessions, week_date)),
      goal: attributed_goal(user_id, session, today),
      days_since_last: session.days_since_last
    }

    events = Milestones.detect(input)

    unless future_completed_session?(user_id, completed_at) do
      persist_bests(user_id, today, %{
        week_after: week_after,
        best_week: stats.best_week_pushups,
        session_pushups: session_pushups,
        best_session: stats.best_session_pushups,
        pace: pace,
        pace_qualifies?: pace_qualifies?,
        best_pace: stats.best_pace_sec_per_burpee,
        lifetime_after: lifetime_after,
        lifetime_milestone: stats.lifetime_pushup_milestone
      })
    end

    events
  end

  defp attributed_goal(user_id, %WorkoutSession{goal_id: goal_id}, today)
       when is_integer(goal_id) do
    case Repo.get_by(Goal, id: goal_id, user_id: user_id, status: :achieved) do
      %Goal{} = goal ->
        %{
          burpee_type: goal.burpee_type,
          target: goal.burpee_count_target,
          deadline: deadline_category(today, goal.date_target)
        }

      nil ->
        nil
    end
  end

  defp attributed_goal(_user_id, %WorkoutSession{}, _today), do: nil

  defp deadline_category(today, target) do
    case Date.compare(today, target) do
      :lt -> :early
      :eq -> :on_time
      :gt -> :late
    end
  end

  defp session_pace(%WorkoutSession{burpee_count_actual: count, duration_sec_actual: duration})
       when is_integer(count) and is_integer(duration) and count > 0 and duration > 0 do
    qualifies? = duration <= @pace_pr_max_duration and count >= @pace_pr_min_count
    {duration / count, qualifies?}
  end

  defp session_pace(_), do: {nil, false}

  defp week_sessions(sessions, date) do
    week_start = Date.beginning_of_week(date, :monday)

    Enum.filter(sessions, fn session ->
      session_date = DateTime.to_date(session.completed_at)
      Date.beginning_of_week(session_date, :monday) == week_start
    end)
  end

  defp future_completed_session?(user_id, completed_at) do
    Repo.exists?(
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and s.state == :completed and
            s.completed_at > ^completed_at
      )
    )
  end

  defp scoring_sessions_before(user_id, completed_at) do
    Repo.all(
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and s.state == :completed and
            s.completed_at < ^completed_at,
        select: %{
          id: s.id,
          burpee_type: s.burpee_type,
          burpee_count_actual: s.burpee_count_actual,
          duration_sec_actual: s.duration_sec_actual,
          completed_at: s.completed_at,
          tags: s.tags
        }
      )
    )
  end

  defp scoring_session_map(%WorkoutSession{} = session) do
    %{
      id: session.id,
      burpee_type: session.burpee_type,
      burpee_count_actual: session.burpee_count_actual,
      duration_sec_actual: session.duration_sec_actual,
      completed_at: session.completed_at,
      tags: session.tags
    }
  end

  defp localize_scoring_sessions(sessions, timezone) do
    Enum.map(sessions, fn session ->
      local_completed_at = DateTime.shift_zone!(session.completed_at, timezone)
      %{session | completed_at: local_completed_at}
    end)
  end

  defp gamification_stats_before(sessions) do
    session_pushups = Enum.map(sessions, &Scoring.session_pushups/1)
    lifetime = Enum.sum(session_pushups)

    best_week =
      sessions
      |> Enum.group_by(&Date.beginning_of_week(DateTime.to_date(&1.completed_at), :monday))
      |> Enum.map(fn {_week, week_sessions} ->
        week_sessions |> Enum.map(&Scoring.session_pushups/1) |> Enum.sum()
      end)
      |> max_or_zero()

    best_pace =
      sessions
      |> Enum.flat_map(fn session ->
        count = session.burpee_count_actual
        duration = session.duration_sec_actual

        if is_integer(count) and count >= @pace_pr_min_count and is_integer(duration) and
             duration > 0 and duration <= @pace_pr_max_duration,
           do: [duration / count],
           else: []
      end)
      |> min_or_nil()

    %{
      best_week_pushups: best_week,
      best_session_pushups: max_or_zero(session_pushups),
      best_pace_sec_per_burpee: best_pace,
      lifetime_pushup_milestone:
        Milestones.lifetime_milestones()
        |> Enum.filter(&(&1 <= lifetime))
        |> max_or_zero()
    }
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(values), do: Enum.max(values)
  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp session_map(%WorkoutSession{} = s) do
    %{
      burpee_type: s.burpee_type,
      burpee_count_actual: s.burpee_count_actual,
      duration_sec_actual: s.duration_sec_actual,
      tags: s.tags
    }
  end

  defp persist_bests(user_id, today, data) do
    today_str = Date.to_iso8601(today)
    changes = %{}

    changes =
      if data.week_after > data.best_week,
        do:
          Map.merge(changes, %{
            best_week_pushups: data.week_after,
            best_week_pushups_on: today_str
          }),
        else: changes

    changes =
      if data.session_pushups > data.best_session,
        do:
          Map.merge(changes, %{
            best_session_pushups: data.session_pushups,
            best_session_pushups_on: today_str
          }),
        else: changes

    changes =
      if data.pace_qualifies? and is_number(data.pace) and
           (is_nil(data.best_pace) or data.pace < data.best_pace),
         do: Map.merge(changes, %{best_pace_sec_per_burpee: data.pace, best_pace_on: today_str}),
         else: changes

    new_milestone =
      case Enum.filter(
             Milestones.lifetime_milestones(),
             &(&1 > data.lifetime_milestone and &1 <= data.lifetime_after)
           ) do
        [] -> nil
        crossed -> Enum.max(crossed)
      end

    changes =
      if new_milestone,
        do: Map.put(changes, :lifetime_pushup_milestone, new_milestone),
        else: changes

    if changes != %{}, do: upsert_gamification_stats(user_id, changes)
    :ok
  end

  defp upsert_gamification_stats(user_id, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    row =
      changes
      |> Map.put(:user_id, user_id)
      |> Map.put(:updated_at, now)

    Repo.insert_all("user_stats", [row],
      on_conflict: {:replace, Map.keys(changes) ++ [:updated_at]},
      conflict_target: :user_id
    )
  end

  # ---------------------------------------------------------------------------
  # Derived session fields (private)
  # ---------------------------------------------------------------------------

  # If the changeset is invalid skip the DB lookups — the insert will fail
  # anyway and we don't want to charge unnecessary queries.
  defp validate_tracked_capture(changeset, cadence) do
    reps = Ecto.Changeset.get_field(changeset, :burpee_count_actual)
    duration_sec = Ecto.Changeset.get_field(changeset, :duration_sec_actual)

    changeset
    |> validate_cadence_values(cadence)
    |> validate_cadence_length(cadence, reps)
    |> validate_cadence_duration(cadence, duration_sec)
  end

  defp validate_cadence_values(changeset, cadence) do
    if valid_cadence_values?(cadence),
      do: changeset,
      else:
        Ecto.Changeset.add_error(
          changeset,
          :cadence_ms,
          "must be monotonic non-negative timestamps"
        )
  end

  defp valid_cadence_values?(cadence) do
    is_list(cadence) and
      Enum.all?(cadence, &(is_integer(&1) and &1 >= 0)) and
      cadence == Enum.sort(cadence)
  end

  defp validate_cadence_length(changeset, cadence, reps) when is_integer(reps) do
    if length(cadence) == reps,
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :cadence_ms, "must contain one timestamp per rep")
  end

  defp validate_cadence_length(changeset, _cadence, _reps), do: changeset

  defp validate_cadence_duration(changeset, [], _duration_sec), do: changeset

  defp validate_cadence_duration(changeset, cadence, duration_sec)
       when is_integer(duration_sec) do
    if List.last(cadence) <= duration_sec * 1000,
      do: changeset,
      else:
        Ecto.Changeset.add_error(changeset, :cadence_ms, "must finish within session duration")
  end

  defp validate_cadence_duration(changeset, _cadence, _duration_sec), do: changeset

  defp parse_optional_float(nil), do: nil
  defp parse_optional_float(value) when is_float(value), do: value
  defp parse_optional_float(value) when is_integer(value), do: value / 1

  defp parse_optional_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp with_program_deviation_fields(changeset, program_snapshot) when is_map(program_snapshot) do
    if changeset.valid? do
      Ecto.Changeset.change(
        changeset,
        compute_program_deviation_fields(changeset, program_snapshot)
      )
    else
      changeset
    end
  end

  defp compute_program_deviation_fields(changeset, program_snapshot) do
    actual_reps = Ecto.Changeset.get_field(changeset, :burpee_count_actual)
    actual_duration = Ecto.Changeset.get_field(changeset, :duration_sec_actual)
    target_reps = Ecto.Changeset.get_field(changeset, :burpee_count_planned)
    target_duration = Ecto.Changeset.get_field(changeset, :duration_sec_planned)
    cadence_intervals = cadence_intervals_from_changeset(changeset)
    expected_intervals = expected_program_intervals(program_snapshot)

    %{
      reps_delta: reps_delta(actual_reps, target_reps),
      shortened: shortened?(actual_duration, target_duration),
      prescribed_sets_completed: prescribed_sets_completed(program_snapshot, actual_reps),
      recovery_delta_sec: recovery_delta_sec(cadence_intervals, expected_intervals),
      pace_delta_sec: pace_delta_sec(cadence_intervals, expected_intervals),
      cadence_decline: cadence_decline(cadence_intervals, expected_intervals)
    }
  end

  defp reps_delta(actual_reps, target_reps)
       when is_integer(actual_reps) and is_integer(target_reps),
       do: actual_reps - target_reps

  defp reps_delta(_actual_reps, _target_reps), do: nil

  defp shortened?(actual_duration, target_duration)
       when is_integer(actual_duration) and is_integer(target_duration),
       do: actual_duration < target_duration

  defp shortened?(_actual_duration, _target_duration), do: nil

  defp prescribed_sets_completed(program_snapshot, actual_reps)
       when is_map(program_snapshot) and is_integer(actual_reps) and actual_reps >= 0 do
    program_snapshot
    |> program_work_events()
    |> Enum.reduce_while({0, actual_reps}, fn %{reps: reps}, {completed, remaining_reps} ->
      if remaining_reps >= reps do
        {:cont, {completed + 1, remaining_reps - reps}}
      else
        {:halt, {completed, remaining_reps}}
      end
    end)
    |> elem(0)
  end

  defp prescribed_sets_completed(_program_snapshot, _actual_reps), do: nil

  defp cadence_intervals_from_changeset(changeset) do
    case Ecto.Changeset.get_field(changeset, :cadence_ms) do
      cadence when is_binary(cadence) ->
        with {:ok, timestamps} <- Jason.decode(cadence),
             true <- valid_cadence_values?(timestamps) do
          cadence_intervals(timestamps)
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp cadence_intervals(timestamps) when is_list(timestamps) do
    timestamps
    |> Enum.reduce({0, []}, fn timestamp, {previous_timestamp, acc} ->
      {timestamp, [(timestamp - previous_timestamp) / 1_000 | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp expected_program_intervals(program_snapshot) when is_map(program_snapshot) do
    program_snapshot
    |> program_events()
    |> Enum.reduce({[], nil}, fn
      %{kind: :work, reps: reps, sec_per_rep: sec_per_rep}, {acc, pending_rest_sec}
      when is_integer(reps) and reps > 0 ->
        first_interval =
          if is_integer(pending_rest_sec) and pending_rest_sec > 0 do
            [{:boundary, pending_rest_sec + sec_per_rep}]
          else
            [{:work, sec_per_rep}]
          end

        work_intervals = List.duplicate({:work, sec_per_rep}, max(reps - 1, 0))
        {acc ++ first_interval ++ work_intervals, nil}

      %{kind: :rest, duration_sec: duration_sec}, {acc, _pending_rest_sec}
      when is_integer(duration_sec) and duration_sec >= 0 ->
        {acc, duration_sec}

      _other, acc ->
        acc
    end)
    |> elem(0)
  end

  defp pace_delta_sec(nil, _expected_intervals), do: nil

  defp pace_delta_sec(cadence_intervals, expected_intervals) do
    cadence_intervals
    |> comparable_interval_pairs(expected_intervals, :work)
    |> average_interval_delta()
  end

  defp recovery_delta_sec(nil, _expected_intervals), do: nil

  defp recovery_delta_sec(_cadence_intervals, _expected_intervals), do: nil

  defp cadence_decline(nil, _expected_intervals), do: nil

  defp cadence_decline(cadence_intervals, expected_intervals) do
    work_intervals =
      cadence_intervals
      |> comparable_interval_pairs(expected_intervals, :work)
      |> Enum.map(&elem(&1, 0))

    window_size = min(3, div(length(work_intervals), 2))

    if window_size > 0 do
      Float.round(
        average(Enum.take(work_intervals, -window_size)) -
          average(Enum.take(work_intervals, window_size)),
        3
      )
    else
      nil
    end
  end

  defp comparable_interval_pairs(cadence_intervals, expected_intervals, kind) do
    cadence_intervals
    |> Enum.zip(expected_intervals)
    |> Enum.flat_map(fn
      {actual, {:work, expected}} when kind == :work -> [{actual, expected}]
      {actual, {:boundary, expected}} when kind == :boundary -> [{actual, expected}]
      _other -> []
    end)
  end

  defp average_interval_delta([]), do: nil

  defp average_interval_delta(pairs) do
    {actual_total, expected_total, count} =
      Enum.reduce(pairs, {0.0, 0.0, 0}, fn {actual, expected},
                                           {actual_acc, expected_acc, count} ->
        {actual_acc + actual, expected_acc + expected, count + 1}
      end)

    Float.round(actual_total / count - expected_total / count, 3)
  end

  defp average(values) do
    Enum.sum(values) / length(values)
  end

  defp program_work_events(program_snapshot) when is_map(program_snapshot) do
    program_snapshot
    |> program_events()
    |> Enum.filter(&match?(%{kind: :work}, &1))
  end

  defp program_events(program_snapshot) when is_map(program_snapshot) do
    program_snapshot
    |> field_value(:events)
    |> List.wrap()
    |> Enum.flat_map(fn
      event when is_map(event) -> [execution_program_event(event)]
      _other -> []
    end)
  end

  defp execution_program_event(event) do
    case field_value(event, :kind) do
      kind when kind in ["work", :work] ->
        %{
          kind: :work,
          reps: field_value(event, :reps),
          sec_per_rep: execution_program_sec_per_rep(event)
        }

      kind when kind in ["rest", :rest] ->
        %{
          kind: :rest,
          duration_sec: execution_program_rest_duration(event)
        }

      _other ->
        %{kind: :unknown}
    end
  end

  defp execution_program_sec_per_rep(event) do
    case field_value(event, :sec_per_rep_us) do
      value when is_integer(value) -> value / 1_000_000
      _other -> 0.0
    end
  end

  defp execution_program_rest_duration(event) do
    case field_value(event, :duration_ms) do
      value when is_integer(value) -> div(value, 1_000)
      _other -> 0
    end
  end

  defp with_derived_session_fields(changeset, user_id, timezone) do
    if changeset.valid? do
      burpee_type = Ecto.Changeset.get_field(changeset, :burpee_type)
      derived = compute_session_derived_fields(user_id, burpee_type, changeset, timezone)
      Ecto.Changeset.change(changeset, derived)
    else
      changeset
    end
  end

  defp compute_session_derived_fields(user_id, burpee_type, changeset, timezone) do
    count = Ecto.Changeset.get_field(changeset, :burpee_count_actual)
    duration = Ecto.Changeset.get_field(changeset, :duration_sec_actual)
    completed_at = Ecto.Changeset.get_field(changeset, :completed_at)

    rate =
      if is_integer(count) and is_integer(duration) and duration > 0,
        do: count / duration * 60

    local_completed_at =
      (completed_at || DateTime.utc_now())
      |> DateTime.shift_zone!(timezone)

    session_date = DateTime.to_date(local_completed_at)
    bucket_hour = local_completed_at.hour
    prev = fetch_prev_session(user_id, burpee_type, completed_at)

    days_since =
      if prev do
        {:ok, previous_date} = UserTime.local_date(prev.completed_at, timezone)
        Date.diff(session_date, previous_date)
      end

    rate_delta =
      if prev && is_number(rate) && is_number(prev.rate_per_min_actual),
        do: rate - prev.rate_per_min_actual

    %{
      rate_per_min_actual: rate,
      time_of_day_bucket: time_of_day_bucket(bucket_hour),
      days_since_last: days_since,
      rate_delta: rate_delta,
      rate_avg_rolling_3: compute_rate_rolling(user_id, burpee_type, rate, completed_at)
    }
  end

  defp fetch_prev_session(user_id, burpee_type, completed_at) do
    Repo.one(
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and s.burpee_type == ^burpee_type and
            s.state == :completed and s.completed_at < ^completed_at,
        order_by: [desc: s.completed_at, desc: s.id],
        limit: 1
      )
    )
  end

  defp compute_rate_rolling(_user_id, _burpee_type, nil, _completed_at), do: nil

  defp compute_rate_rolling(user_id, burpee_type, current_rate, completed_at) do
    prev_rates =
      Repo.all(
        from(s in WorkoutSession,
          where:
            s.user_id == ^user_id and s.burpee_type == ^burpee_type and
              s.state == :completed and s.completed_at < ^completed_at and
              not is_nil(s.rate_per_min_actual),
          order_by: [desc: s.completed_at, desc: s.id],
          limit: 2,
          select: s.rate_per_min_actual
        )
      )

    # Oldest first, then current session — EMA gives more weight to recent.
    ema(Enum.reverse(prev_rates) ++ [current_rate], 0.5)
  end

  defp ema([r], _alpha), do: r

  defp ema([r | rest], alpha) do
    Enum.reduce(rest, r, fn rate, acc -> alpha * rate + (1.0 - alpha) * acc end)
  end

  defp time_of_day_bucket(hour) do
    cond do
      hour in 6..11 -> "morning"
      hour in 12..16 -> "afternoon"
      hour in 17..20 -> "evening"
      true -> "night"
    end
  end

  @doc "Commit a generated first-use draft and its Home pointer atomically."
  def commit_home_bootstrap(%Scope{user: %User{} = user} = scope, slot, definition, text) do
    immediate_lifecycle_transaction(fn ->
      with :ok <- verified_bootstrap_slot(user, slot),
           :ok <- no_other_started_session(user),
           {:ok, recommendation} <-
             ensure_recommendation(scope, Map.take(slot, [:slot_key, :slot_date])),
           {:ok, content} <-
             canonical_draft_content(%{definition: definition, request_text: text}),
           {:ok, draft} <- save_authored_draft(user, nil, content),
           {:ok, changed} <- write_home_pointer(recommendation, draft.id) do
        {:ok, HomeSelection.new(changed, draft)}
      end
    end)
  end

  @doc "Commit authored content against the exact Home selection CAS."
  def commit_home_revision(%Scope{user: %User{} = user} = scope, expected, definition, text) do
    immediate_lifecycle_transaction(fn ->
      with {:ok, r} <- home_recommendation(user, expected),
           {:ok, source} <- verify_home_selection(scope, expected),
           {:ok, content} <-
             canonical_draft_content(%{definition: definition, request_text: text}),
           {:ok, draft} <- save_authored_draft(user, source, content),
           {:ok, changed} <- write_home_pointer(r, draft.id) do
        {:ok, HomeSelection.new(changed, draft)}
      end
    end)
  end

  @doc "Idempotently publish canonical content under an owner-bound approval key."
  def commit_approved_workout(%Scope{user: %User{} = user}, definition, text, opts)
      when is_list(opts) do
    key = Keyword.fetch!(opts, :approval_key)

    immediate_lifecycle_transaction(fn ->
      case Repo.get_by(WorkoutPlan, approval_key: key) do
        %WorkoutPlan{user_id: id, definition_json: ^definition} = plan when id == user.id ->
          with :ok <- verify_stored_draft(plan), do: {:ok, plan}

        %WorkoutPlan{} ->
          {:error, Error.new(:design_workspace_changed)}

        nil ->
          with true <- is_binary(key) and byte_size(key) in 1..200,
               {:ok, content} <-
                 canonical_draft_content(%{definition: definition, request_text: text}),
               {:ok, draft} <-
                 %WorkoutPlan{user_id: user.id, origin: :user, state: :draft, approval_key: key}
                 |> WorkoutPlan.new_draft_changeset(content)
                 |> Repo.insert()
                 |> normalize_plan_write() do
            publish_unattached_draft(user, draft.id)
          else
            false -> {:error, Error.new(:design_workspace_changed)}
            {:error, error} -> {:error, error}
          end
      end
    end)
  end

  defp save_authored_draft(_user, %{state: :draft} = source, content) do
    source
    |> WorkoutPlan.replace_draft_changeset(content)
    |> Repo.update()
    |> normalize_plan_write()
  end

  defp save_authored_draft(user, _published_or_nil, content) do
    %WorkoutPlan{user_id: user.id, origin: :user, state: :draft}
    |> WorkoutPlan.new_draft_changeset(content)
    |> Repo.insert()
    |> normalize_plan_write()
  end
end
