defmodule BurpeeTrainer.Workouts do
  @moduledoc """
  Context for workout plans (with blocks + sets) and workout sessions.
  All queries are scoped by `user_id`.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach.Learning
  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.{Block, StylePerformance, WorkoutPlan, WorkoutSession}

  # ---------------------------------------------------------------------------
  # Plans
  # ---------------------------------------------------------------------------

  @doc """
  List all plans for a user, preloading blocks and sets so the timeline
  can be computed without further queries.
  """
  @spec list_plans(User.t()) :: [WorkoutPlan.t()]
  def list_plans(%User{id: user_id}) do
    Repo.all(
      from plan in WorkoutPlan,
        where: plan.user_id == ^user_id,
        order_by: [desc: plan.updated_at],
        preload: [blocks: :sets]
    )
  end

  @doc """
  Fetch a plan by id for a user, with blocks + sets preloaded.
  Raises if the plan doesn't exist or belongs to a different user.
  """
  @spec get_plan!(User.t(), integer) :: WorkoutPlan.t()
  def get_plan!(%User{id: user_id}, id) do
    Repo.one!(
      from plan in WorkoutPlan,
        where: plan.id == ^id and plan.user_id == ^user_id,
        preload: [blocks: :sets]
    )
  end

  @doc """
  Return a blank changeset for a new plan, suitable for rendering a
  create form.
  """
  @spec change_plan(WorkoutPlan.t(), map) :: Ecto.Changeset.t()
  def change_plan(%WorkoutPlan{} = plan, attrs \\ %{}) do
    WorkoutPlan.changeset(plan, attrs)
  end

  @doc """
  Create a plan for a user. `user_id` is set programmatically — never
  trust it from form attrs.
  """
  @spec create_plan(User.t(), map) :: {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def create_plan(%User{id: user_id}, attrs) do
    %WorkoutPlan{user_id: user_id}
    |> WorkoutPlan.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a plan. Caller must have obtained the plan via `get_plan!/2`
  so ownership is already enforced.
  """
  @spec update_plan(WorkoutPlan.t(), map) ::
          {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def update_plan(%WorkoutPlan{} = plan, attrs) do
    plan
    |> WorkoutPlan.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a plan. Cascades to blocks and sets via FK. Sessions that
  referenced the plan have their `plan_id` nilified.
  """
  @spec delete_plan(WorkoutPlan.t()) :: {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def delete_plan(%WorkoutPlan{} = plan), do: Repo.delete(plan)

  @doc """
  Duplicate a plan (new row, same content, suffixed name). Blocks and
  sets are recreated with fresh ids.
  """
  @spec duplicate_plan(WorkoutPlan.t()) ::
          {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def duplicate_plan(%WorkoutPlan{} = plan) do
    source = Repo.preload(plan, blocks: :sets)

    attrs = %{
      "name" => source.name <> " (copy)",
      "burpee_type" => source.burpee_type,
      "target_duration_min" => source.target_duration_min,
      "burpee_count_target" => source.burpee_count_target,
      "sec_per_burpee" => source.sec_per_burpee,
      "pacing_style" => source.pacing_style,
      "additional_rests" => source.additional_rests,
      "style_name" => source.style_name,
      "blocks" => duplicate_plan_blocks(source.blocks)
    }

    create_plan(%User{id: source.user_id}, attrs)
  end

  defp duplicate_plan_blocks(blocks) do
    for block <- Enum.sort_by(blocks, & &1.position) do
      %{
        "position" => block.position,
        "repeat_count" => block.repeat_count,
        "sets" => duplicate_plan_sets(block.sets)
      }
    end
  end

  defp duplicate_plan_sets(sets) do
    for set <- Enum.sort_by(sets, & &1.position) do
      %{
        "position" => set.position,
        "burpee_count" => set.burpee_count,
        "sec_per_rep" => set.sec_per_rep,
        "sec_per_burpee" => set.sec_per_burpee,
        "end_of_set_rest" => set.end_of_set_rest
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc """
  List sessions for a user, most recent first. Optional `burpee_type`
  filter.
  """
  @spec list_sessions(User.t()) :: [WorkoutSession.t()]
  def list_sessions(%User{id: user_id}) do
    Repo.all(
      from session in WorkoutSession,
        where: session.user_id == ^user_id,
        order_by: [desc: session.inserted_at]
    )
  end

  @spec list_sessions(User.t(), atom) :: [WorkoutSession.t()]
  def list_sessions(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from session in WorkoutSession,
        where: session.user_id == ^user_id and session.burpee_type == ^burpee_type,
        order_by: [desc: session.inserted_at]
    )
  end

  @doc """
  Return per-ISO-week training minutes for a user, excluding warmup sessions.
  Weeks are Mon–Sun. Result is sorted descending by `week_start`.
  """
  @spec weekly_minutes(User.t()) :: [%{week_start: Date.t(), minutes: float, met_goal: bool}]
  def weekly_minutes(%User{id: user_id}) do
    sessions =
      Repo.all(
        from s in WorkoutSession,
          where:
            s.user_id == ^user_id and
              (is_nil(s.tags) or s.tags != "warmup"),
          select: %{inserted_at: s.inserted_at, duration_sec_actual: s.duration_sec_actual}
      )

    sessions
    |> Enum.group_by(fn %{inserted_at: dt} ->
      dt |> DateTime.to_date() |> Date.beginning_of_week(:monday)
    end)
    |> Enum.map(fn {week_start, rows} ->
      minutes = Enum.sum_by(rows, & &1.duration_sec_actual) / 60.0
      %{week_start: week_start, minutes: minutes, met_goal: minutes >= 79.0}
    end)
    |> Enum.sort_by(& &1.week_start, {:desc, Date})
  end

  @doc """
  Returns a MapSet of dates (Mon–Sun of the current ISO week) on which the
  user completed at least one non-warmup session.
  """
  @spec this_week_trained_days(User.t()) :: MapSet.t()
  def this_week_trained_days(%User{id: user_id}) do
    today = Date.utc_today()
    week_start = Date.beginning_of_week(today, :monday)
    week_end = Date.add(week_start, 6)

    week_start_dt = DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")
    week_end_dt = DateTime.new!(week_end, ~T[23:59:59], "Etc/UTC")

    Repo.all(
      from s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            (is_nil(s.tags) or s.tags != "warmup") and
            s.inserted_at >= ^week_start_dt and
            s.inserted_at <= ^week_end_dt,
        select: s.inserted_at
    )
    |> Enum.map(&DateTime.to_date/1)
    |> MapSet.new()
  end

  @doc """
  Returns the `%WorkoutPlan{}` (blocks preloaded) from the most recent
  non-warmup session that has a plan_id, or `nil` if none exists.
  """
  @spec last_run_plan(User.t()) :: WorkoutPlan.t() | nil
  def last_run_plan(%User{id: user_id}) do
    result =
      Repo.one(
        from s in WorkoutSession,
          join: p in WorkoutPlan,
          on: p.id == s.plan_id,
          where:
            s.user_id == ^user_id and
              not is_nil(s.plan_id) and
              (is_nil(s.tags) or s.tags != "warmup"),
          order_by: [desc: s.inserted_at],
          limit: 1,
          select: p
      )

    case result do
      nil -> nil
      plan -> Repo.preload(plan, :blocks)
    end
  end

  @doc """
  Cursor-based paginated sessions. Returns `{sessions, has_more?}`.

  Pass `before: datetime` to fetch the page older than that cursor.
  Fetches `limit + 1` rows to determine if another page exists.
  """
  @spec list_sessions_page(User.t(), pos_integer(), keyword()) ::
          {[WorkoutSession.t()], boolean()}
  def list_sessions_page(%User{id: user_id}, limit, opts \\ []) do
    before_dt = Keyword.get(opts, :before)

    query =
      from s in WorkoutSession,
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at],
        limit: ^(limit + 1),
        preload: [:plan, :goal]

    query =
      if before_dt,
        do: where(query, [s], s.inserted_at < ^before_dt),
        else: query

    rows = Repo.all(query)
    has_more = length(rows) > limit
    {Enum.take(rows, limit), has_more}
  end

  @doc """
  Most recent session for a user + burpee type that has usable baseline data:
  burpee_count_actual > 0 and duration_sec_actual between 1190 and 1210 (20 min ± 10 sec).
  """
  @spec last_session_for_type(User.t(), atom) :: WorkoutSession.t() | nil
  def last_session_for_type(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.one(
      from s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual >= 1190 and
            s.duration_sec_actual <= 1210,
        order_by: [desc: s.inserted_at],
        limit: 1
    )
  end

  @doc """
  All-time best qualifying session (highest burpee_count_actual) for a user + burpee type.
  Qualifying = duration_sec_actual in [1190, 1210] and burpee_count_actual > 0.
  Returns nil if no qualifying sessions exist.
  """
  @spec best_qualifying_session(User.t(), atom) :: WorkoutSession.t() | nil
  def best_qualifying_session(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.one(
      from s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual >= 1190 and
            s.duration_sec_actual <= 1210,
        order_by: [desc: s.burpee_count_actual],
        limit: 1
    )
  end

  @doc """
  All sessions for a user + burpee type suitable for progress charting:
  burpee_count_actual > 0 and duration_sec_actual > 0, ordered oldest first.
  """
  @spec list_sessions_for_chart(User.t(), atom) :: [WorkoutSession.t()]
  def list_sessions_for_chart(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual > 0,
        order_by: [asc: s.inserted_at]
    )
  end

  @doc """
  Tags a session as the one that achieved a goal by setting its goal_id.
  """
  @spec tag_session_as_goal_reached(WorkoutSession.t(), integer) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
  def tag_session_as_goal_reached(%WorkoutSession{} = session, goal_id) do
    session
    |> Ecto.Changeset.change(goal_id: goal_id)
    |> Repo.update()
  end

  @doc """
  Create a session that followed a plan. `user_id` and `plan_id` are
  set programmatically. Derived analytics fields (rate, rolling average,
  days since last, time-of-day bucket) are computed before insert.
  """
  @spec create_session_from_plan(User.t(), WorkoutPlan.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
  def create_session_from_plan(%User{id: user_id}, %WorkoutPlan{id: plan_id} = plan, attrs) do
    changeset =
      %WorkoutSession{user_id: user_id, plan_id: plan_id}
      |> WorkoutSession.from_plan_changeset(attrs)
      |> with_derived_session_fields(user_id)
      |> maybe_carry_style_name(plan)

    case Repo.insert(changeset) do
      {:ok, session} ->
        maybe_upsert_style_performance(session, user_id)
        Learning.record_session_completed(%User{id: user_id}, session)
        {:ok, session}

      error ->
        error
    end
  end

  @doc """
  Create a completed plan session and optional warmup atomically.
  """
  @spec create_session_from_plan_with_warmup(User.t(), WorkoutPlan.t(), map, map | nil) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t() | any}
  def create_session_from_plan_with_warmup(user, plan, attrs, nil) do
    create_session_from_plan(user, plan, attrs)
  end

  def create_session_from_plan_with_warmup(
        %User{} = user,
        %WorkoutPlan{} = plan,
        attrs,
        warmup_attrs
      ) do
    Repo.transaction(fn ->
      with {:ok, _warmup} <- create_warmup_session(user, warmup_attrs),
           {:ok, session} <- create_session_from_plan(user, plan, attrs) do
        session
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Save a warmup session silently (no UI shown). `plan_id` is nil.
  Tagged "warmup" so it's distinguishable in history.
  """
  @spec create_warmup_session(User.t(), map) :: {:ok, WorkoutSession.t()} | {:error, any}
  def create_warmup_session(%User{id: user_id}, %{
        burpee_type: bt,
        burpee_count_done: count,
        duration_sec: duration
      }) do
    attrs = %{
      "burpee_type" => Atom.to_string(bt),
      "burpee_count_actual" => count,
      "duration_sec_actual" => duration,
      "burpee_count_planned" => count,
      "duration_sec_planned" => duration,
      "tags" => "warmup"
    }

    %WorkoutSession{user_id: user_id}
    |> WorkoutSession.free_form_changeset(attrs)
    |> with_derived_session_fields(user_id)
    |> Repo.insert()
  end

  @doc """
  Create a free-form session (no plan reference). `user_id` is set
  programmatically. Same derived-field computation as plan sessions.
  """
  @spec create_free_form_session(User.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
  def create_free_form_session(%User{id: user_id}, attrs) do
    %WorkoutSession{user_id: user_id}
    |> WorkoutSession.free_form_changeset(attrs)
    |> with_derived_session_fields(user_id)
    |> Repo.insert()
  end

  @doc """
  Blank changeset builders for forms.
  """
  @spec change_free_form_session(WorkoutSession.t(), map) :: Ecto.Changeset.t()
  def change_free_form_session(%WorkoutSession{} = session, attrs \\ %{}) do
    WorkoutSession.free_form_changeset(session, attrs)
  end

  @spec change_session_from_plan(WorkoutSession.t(), map) :: Ecto.Changeset.t()
  def change_session_from_plan(%WorkoutSession{} = session, attrs \\ %{}) do
    WorkoutSession.from_plan_changeset(session, attrs)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  List all style performances for a user.
  """
  @spec list_style_performances(User.t()) :: [StylePerformance.t()]
  def list_style_performances(%User{id: user_id}) do
    Repo.all(from sp in StylePerformance, where: sp.user_id == ^user_id)
  end

  @doc """
  Persist a wizard-generated (unsaved) `%WorkoutPlan{}` struct for a user.
  Converts the struct to changeset-compatible attrs.
  """
  @spec save_generated_plan(User.t(), WorkoutPlan.t()) ::
          {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def save_generated_plan(%User{} = user, %WorkoutPlan{} = plan) do
    attrs = %{
      "name" => plan.name,
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "style_name" => plan.style_name,
      "target_duration_min" => plan.target_duration_min,
      "burpee_count_target" => plan.burpee_count_target,
      "sec_per_burpee" => plan.sec_per_burpee,
      "pacing_style" => plan.pacing_style,
      "additional_rests" => plan.additional_rests,
      "blocks" => save_generated_plan_blocks(plan.blocks)
    }

    create_plan(user, attrs)
  end

  defp save_generated_plan_blocks(blocks) do
    for block <- Enum.sort_by(blocks, & &1.position) do
      %{
        "position" => block.position,
        "repeat_count" => block.repeat_count,
        "sets" => save_generated_plan_sets(block.sets)
      }
    end
  end

  defp save_generated_plan_sets(sets) do
    for set <- Enum.sort_by(sets, & &1.position) do
      %{
        "position" => set.position,
        "burpee_count" => set.burpee_count,
        "sec_per_rep" => set.sec_per_rep,
        "sec_per_burpee" => set.sec_per_burpee,
        "end_of_set_rest" => set.end_of_set_rest
      }
    end
  end

  @doc false
  def preload_plan(%WorkoutPlan{} = plan), do: Repo.preload(plan, blocks: :sets)

  @doc """
  Reorder blocks within a plan by supplying `[{block_id, position}, ...]`.
  """
  @spec reorder_blocks(WorkoutPlan.t(), [{integer, integer}]) :: :ok
  def reorder_blocks(%WorkoutPlan{id: plan_id}, id_positions) when is_list(id_positions) do
    Repo.transaction(fn ->
      Enum.each(id_positions, fn {block_id, position} ->
        Repo.update_all(
          from(b in Block, where: b.id == ^block_id and b.plan_id == ^plan_id),
          set: [position: position]
        )
      end)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Derived session fields (private)
  # ---------------------------------------------------------------------------

  # If the changeset is invalid skip the DB lookups — the insert will fail
  # anyway and we don't want to charge unnecessary queries.
  defp with_derived_session_fields(changeset, user_id) do
    if changeset.valid? do
      burpee_type = Ecto.Changeset.get_field(changeset, :burpee_type)
      derived = compute_session_derived_fields(user_id, burpee_type, changeset)
      Ecto.Changeset.change(changeset, derived)
    else
      changeset
    end
  end

  defp compute_session_derived_fields(user_id, burpee_type, changeset) do
    count = Ecto.Changeset.get_field(changeset, :burpee_count_actual)
    duration = Ecto.Changeset.get_field(changeset, :duration_sec_actual)
    inserted_at_override = Ecto.Changeset.get_field(changeset, :inserted_at)

    rate =
      if is_integer(count) and is_integer(duration) and duration > 0,
        do: count / duration * 60

    session_date =
      if inserted_at_override,
        do: DateTime.to_date(inserted_at_override),
        else: Date.utc_today()

    bucket_hour =
      if inserted_at_override,
        do: inserted_at_override.hour,
        else: DateTime.utc_now().hour

    prev = fetch_prev_session(user_id, burpee_type)

    days_since =
      if prev, do: Date.diff(session_date, DateTime.to_date(prev.inserted_at))

    rate_delta =
      if prev && is_number(rate) && is_number(prev.rate_per_min_actual),
        do: rate - prev.rate_per_min_actual

    %{
      rate_per_min_actual: rate,
      time_of_day_bucket: time_of_day_bucket(bucket_hour),
      days_since_last: days_since,
      rate_delta: rate_delta,
      rate_avg_rolling_3: compute_rate_rolling(user_id, burpee_type, rate)
    }
  end

  defp fetch_prev_session(user_id, burpee_type) do
    Repo.one(
      from s in WorkoutSession,
        where: s.user_id == ^user_id and s.burpee_type == ^burpee_type,
        order_by: [desc: s.inserted_at],
        limit: 1
    )
  end

  defp compute_rate_rolling(_user_id, _burpee_type, nil), do: nil

  defp compute_rate_rolling(user_id, burpee_type, current_rate) do
    prev_rates =
      Repo.all(
        from s in WorkoutSession,
          where:
            s.user_id == ^user_id and s.burpee_type == ^burpee_type and
              not is_nil(s.rate_per_min_actual),
          order_by: [desc: s.inserted_at],
          limit: 2,
          select: s.rate_per_min_actual
      )

    # Oldest first, then current session — EMA gives more weight to recent.
    ema(Enum.reverse(prev_rates) ++ [current_rate], 0.5)
  end

  defp ema([], _alpha), do: nil
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

  # Copy the plan's style_name onto the session changeset when present.
  defp maybe_carry_style_name(changeset, %{style_name: name}) when is_binary(name) do
    Ecto.Changeset.put_change(changeset, :style_name, name)
  end

  defp maybe_carry_style_name(changeset, _plan), do: changeset

  # No-op when the session has no style attribution.
  defp maybe_upsert_style_performance(%{style_name: nil}, _user_id), do: :ok
  defp maybe_upsert_style_performance(%{style_name: ""}, _user_id), do: :ok

  defp maybe_upsert_style_performance(session, user_id) do
    bt = session.burpee_type

    level =
      Repo.all(
        from s in WorkoutSession,
          where: s.user_id == ^user_id and s.burpee_type == ^bt,
          select: %{
            burpee_type: s.burpee_type,
            burpee_count_actual: s.burpee_count_actual,
            duration_sec_actual: s.duration_sec_actual
          }
      )
      |> Levels.level_for_type(bt)
      |> Atom.to_string()

    completion_ratio =
      if is_integer(session.burpee_count_planned) and session.burpee_count_planned > 0,
        do: session.burpee_count_actual / session.burpee_count_planned,
        else: 1.0

    upsert_style_performance_record(%{
      user_id: user_id,
      style_name: session.style_name,
      burpee_type: bt,
      mood: session.mood || 0,
      level: level,
      time_of_day_bucket: session.time_of_day_bucket || "morning",
      completion_ratio: completion_ratio,
      rate: session.rate_per_min_actual || 0.0
    })
  end

  defp upsert_style_performance_record(%{
         user_id: user_id,
         style_name: style_name,
         burpee_type: bt,
         mood: mood,
         level: level,
         time_of_day_bucket: bucket,
         completion_ratio: cr,
         rate: rate
       }) do
    key = [
      user_id: user_id,
      style_name: style_name,
      burpee_type: bt,
      mood: mood,
      level: level,
      time_of_day_bucket: bucket
    ]

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(StylePerformance, key) do
      nil ->
        Repo.insert!(%StylePerformance{
          user_id: user_id,
          style_name: style_name,
          burpee_type: bt,
          mood: mood,
          level: level,
          time_of_day_bucket: bucket,
          session_count: 1,
          completion_ratio_sum: cr,
          rate_sum: rate,
          inserted_at: now,
          updated_at: now
        })

      existing ->
        existing
        |> Ecto.Changeset.change(%{
          session_count: existing.session_count + 1,
          completion_ratio_sum: existing.completion_ratio_sum + cr,
          rate_sum: existing.rate_sum + rate,
          updated_at: now
        })
        |> Repo.update!()
    end

    :ok
  end
end
