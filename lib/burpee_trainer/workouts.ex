defmodule BurpeeTrainer.Workouts do
  @moduledoc """
  Context for workout source plans and workout sessions.
  All queries are scoped by `user_id`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.{ExecutionPrograms, PlanCompiler}
  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Milestones
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Scoring
  alias BurpeeTrainer.Workouts.PaceConsistency

  alias BurpeeTrainer.Workouts.{
    ExecutionProgram,
    PoseCaptureRun,
    PoseTraceChunk,
    StylePerformance,
    WorkoutPlan,
    WorkoutSession,
    WorkoutVideo
  }

  # A session is eligible to set a pace PR only when it is a genuine effort:
  # a full-length-ish bout (≤ 20 min) of at least this many burpees.
  @pace_pr_min_count 20
  @pace_pr_max_duration 1200

  # ---------------------------------------------------------------------------
  # Plans
  # ---------------------------------------------------------------------------

  @doc """
  List all source plans for a user.
  """
  @spec list_plans(User.t()) :: [WorkoutPlan.t()]
  def list_plans(%User{id: user_id}) do
    Repo.all(
      from(plan in WorkoutPlan,
        where: plan.user_id == ^user_id,
        order_by: [desc: plan.updated_at]
      )
    )
  end

  @doc """
  Fetch a source plan by id for a user.
  Raises if the plan doesn't exist or belongs to a different user.
  """
  @spec get_plan!(User.t(), integer) :: WorkoutPlan.t()
  def get_plan!(%User{id: user_id}, id) do
    Repo.one!(
      from(plan in WorkoutPlan,
        where: plan.id == ^id and plan.user_id == ^user_id
      )
    )
  end

  @doc """
  Return a blank changeset for a new plan, suitable for rendering a
  create form.
  """
  @spec change_plan(WorkoutPlan.t(), map) :: Ecto.Changeset.t()
  def change_plan(%WorkoutPlan{} = plan, attrs \\ %{}) do
    WorkoutPlan.changeset(plan, normalize_plan_attrs(attrs))
  end

  @doc """
  Create a plan for a user. `user_id` is set programmatically — never
  trust it from form attrs.
  """
  @spec create_plan(User.t(), map) ::
          {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_plan(%User{id: user_id}, attrs) do
    with source when is_map(source) <- source_json_from_attrs(attrs),
         {:ok, program} <- PlanCompiler.compile(source),
         {:ok, persisted_program} <- ExecutionPrograms.get_or_insert(program) do
      attrs =
        attrs
        |> Map.put("current_execution_program_id", persisted_program.id)
        |> Map.put("source_json", source)
        |> put_source_summary(program, source)

      %WorkoutPlan{user_id: user_id}
      |> WorkoutPlan.changeset(normalize_plan_attrs(attrs))
      |> Repo.insert()
    else
      {:error, _reason} = error -> error
      _missing_or_invalid_source -> PlanCompiler.compile(%{})
    end
  end

  @doc """
  Update a plan. Caller must have obtained the plan via `get_plan!/2`
  so ownership is already enforced.
  """
  @spec update_plan(WorkoutPlan.t(), map) ::
          {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_plan(%WorkoutPlan{} = plan, attrs) do
    attrs =
      if source_json_from_attrs(attrs) do
        attrs
      else
        Map.put(attrs, "source_json", plan.source_json)
      end

    with source when is_map(source) <- source_json_from_attrs(attrs),
         {:ok, program} <- PlanCompiler.compile(source),
         {:ok, persisted_program} <- ExecutionPrograms.get_or_insert(program) do
      attrs =
        attrs
        |> Map.put("current_execution_program_id", persisted_program.id)
        |> Map.put("source_json", source)
        |> put_source_summary(program, source)

      plan
      |> WorkoutPlan.changeset(normalize_plan_attrs(attrs))
      |> Repo.update()
    else
      {:error, _reason} = error -> error
      _missing_or_invalid_source -> PlanCompiler.compile(%{})
    end
  end

  @spec compile_plan(WorkoutPlan.t()) :: {:ok, ExecutionProgram.t()} | {:error, term()}
  def compile_plan(%WorkoutPlan{current_execution_program_id: id} = plan)
      when is_integer(id) do
    current_program = ExecutionPrograms.get!(id)

    if current_program.schema_version == PlanCompiler.schema_version() do
      {:ok, current_program}
    else
      case compile_current_program(plan) do
        {:ok, upgraded_program} -> {:ok, upgraded_program}
        {:error, _reason} -> {:ok, current_program}
      end
    end
  end

  def compile_plan(%WorkoutPlan{source_json: source} = plan) when is_map(source) do
    compile_current_program(plan)
  end

  def compile_plan(%WorkoutPlan{}), do: {:error, :missing_source_json}

  defp compile_current_program(%WorkoutPlan{source_json: source} = plan) when is_map(source) do
    with {:ok, program} <- PlanCompiler.compile(source),
         {:ok, persisted_program} <- ExecutionPrograms.get_or_insert(program),
         :ok <- put_current_execution_program(plan, persisted_program) do
      {:ok, persisted_program}
    end
  end

  defp compile_current_program(%WorkoutPlan{}), do: {:error, :missing_source_json}

  defp put_current_execution_program(%WorkoutPlan{id: nil}, _program), do: :ok

  defp put_current_execution_program(%WorkoutPlan{} = plan, %ExecutionProgram{} = program) do
    plan
    |> Ecto.Changeset.change(current_execution_program_id: program.id)
    |> Repo.update()
    |> case do
      {:ok, _plan} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp source_json_from_attrs(attrs) do
    Map.get(attrs, "source_json") || Map.get(attrs, :source_json)
  end

  defp put_source_summary(attrs, %BurpeeTrainer.PlanCompiler.Program{} = program, source) do
    attrs
    |> Map.put("burpee_type", Atom.to_string(program.burpee_type))
    |> Map.put("target_duration_min", round(program.target_duration_sec / 60))
    |> Map.put("burpee_count_target", program.target_reps)
    |> Map.put("sec_per_burpee", average_work_pace(program))
    |> Map.put("pacing_style", source_pacing_style(source))
  end

  defp source_pacing_style(%{"pacing_style" => style}) when is_atom(style),
    do: Atom.to_string(style)

  defp source_pacing_style(%{"pacing_style" => style}) when is_binary(style), do: style
  defp source_pacing_style(%{pacing_style: style}) when is_atom(style), do: Atom.to_string(style)
  defp source_pacing_style(%{pacing_style: style}) when is_binary(style), do: style

  defp average_work_pace(%{metadata: %{work_interval_sec: pace}}) when is_number(pace),
    do: Float.round(pace, 1)

  defp average_work_pace(program) do
    work_events =
      Enum.filter(program.events, &match?(%BurpeeTrainer.PlanCompiler.ProgramEvent.Work{}, &1))

    total_reps = Enum.reduce(work_events, 0, &(&1.reps + &2))
    total_work = Enum.reduce(work_events, 0.0, &(&1.reps * &1.sec_per_burpee + &2))

    if total_reps > 0, do: Float.round(total_work / total_reps, 1), else: 0.0
  end

  @doc """
  Delete a plan. Sessions that referenced the plan have their `plan_id` nilified.
  """
  @spec delete_plan(WorkoutPlan.t()) :: {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def delete_plan(%WorkoutPlan{} = plan), do: Repo.delete(plan)

  @doc """
  Duplicate a source plan (new row, same source, suffixed name) and compile a fresh program.
  """
  @spec duplicate_plan(WorkoutPlan.t()) ::
          {:ok, WorkoutPlan.t()} | {:error, Ecto.Changeset.t()}
  def duplicate_plan(%WorkoutPlan{} = source) do
    attrs = %{
      "name" => source.name <> " (copy)",
      "source_json" => source.source_json
    }

    create_plan(%User{id: source.user_id}, attrs)
  end

  # ---------------------------------------------------------------------------
  # Pose capture
  # ---------------------------------------------------------------------------

  @doc """
  Start a pose capture run for a user's plan.
  """
  @spec start_pose_capture_run(User.t(), WorkoutPlan.t(), map()) ::
          {:ok, PoseCaptureRun.t()} | {:error, Ecto.Changeset.t()}
  def start_pose_capture_run(
        %User{id: user_id},
        %WorkoutPlan{id: plan_id, user_id: user_id},
        attrs \\ %{}
      ) do
    attrs = Map.put_new(attrs, "started_at", DateTime.utc_now(:second))

    %PoseCaptureRun{user_id: user_id, plan_id: plan_id, status: :active}
    |> PoseCaptureRun.start_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Append one raw-ish pose trace chunk to an active capture run.
  """
  @spec append_pose_trace_chunk(User.t(), PoseCaptureRun.t(), map()) ::
          {:ok, PoseTraceChunk.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def append_pose_trace_chunk(%User{id: user_id}, %PoseCaptureRun{id: run_id}, attrs) do
    case get_user_pose_capture_run(user_id, run_id) do
      %PoseCaptureRun{status: :active} = run ->
        %PoseTraceChunk{pose_capture_run_id: run.id}
        |> PoseTraceChunk.changeset(attrs)
        |> Repo.insert()

      %PoseCaptureRun{} ->
        {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Mark a capture run as completed and link it to the saved workout session.
  """
  @spec complete_pose_capture_run(User.t(), PoseCaptureRun.t(), WorkoutSession.t()) ::
          {:ok, PoseCaptureRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def complete_pose_capture_run(
        %User{id: user_id},
        %PoseCaptureRun{id: run_id},
        %WorkoutSession{id: session_id, user_id: user_id}
      ) do
    case get_user_pose_capture_run(user_id, run_id) do
      %PoseCaptureRun{status: :active} = run ->
        run
        |> PoseCaptureRun.complete_changeset(%{
          "workout_session_id" => session_id,
          "completed_at" => DateTime.utc_now(:second)
        })
        |> Repo.update()

      %PoseCaptureRun{} ->
        {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Abort a capture run by deleting the run and all uploaded chunks.

  Aborted tracked workouts must not retain pose data.
  """
  @spec abort_pose_capture_run(User.t(), PoseCaptureRun.t(), String.t() | nil) ::
          :ok | {:error, Ecto.Changeset.t() | :not_found}
  def abort_pose_capture_run(%User{id: user_id}, %PoseCaptureRun{id: run_id}, _reason) do
    case get_user_pose_capture_run(user_id, run_id) do
      %PoseCaptureRun{status: :active} = run ->
        case Repo.delete(run) do
          {:ok, _run} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      %PoseCaptureRun{} ->
        {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Ingest a deferred pose-trace batch for an already-saved, user-scoped session.

  Chunk indexes are idempotent per run only when their stored payload digest
  matches. The run is completed only when the caller marks the final
  acknowledged batch complete.
  """
  @spec ingest_pose_trace_batch(User.t(), String.t(), [map()], boolean()) ::
          {:ok, %{accepted_indexes: [non_neg_integer()], complete: boolean()}}
          | {:error, Ecto.Changeset.t() | :chunk_conflict | :invalid_batch | :not_found}
  def ingest_pose_trace_batch(
        %User{id: user_id},
        client_session_id,
        chunks,
        complete?
      )
      when is_binary(client_session_id) and is_list(chunks) and is_boolean(complete?) do
    Multi.new()
    |> Multi.run(:session, fn repo, _changes ->
      case repo.get_by(WorkoutSession,
             user_id: user_id,
             client_session_id: client_session_id
           ) do
        %WorkoutSession{plan_id: plan_id, status: :reported} = session when not is_nil(plan_id) ->
          {:ok, session}

        _session ->
          {:error, :not_found}
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

  def ingest_pose_trace_batch(%User{}, _client_session_id, _chunks, _complete?),
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
            plan_id: session.plan_id,
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

  defp insert_deferred_pose_chunks(repo, run, chunks) do
    with {:ok, prepared} <- prepare_deferred_pose_chunks(run, chunks) do
      Enum.reduce_while(prepared, {:ok, []}, fn {index, changeset}, {:ok, indexes} ->
        case repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:pose_capture_run_id, :chunk_index]
             ) do
          {:ok, _chunk} ->
            case acknowledge_matching_chunk(repo, run.id, index, changeset) do
              :ok -> {:cont, {:ok, [index | indexes]}}
              {:error, reason} -> {:halt, {:error, reason}}
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

  defp acknowledge_matching_chunk(repo, run_id, index, changeset) do
    digest = Ecto.Changeset.get_field(changeset, :payload_digest)

    case repo.get_by(PoseTraceChunk, pose_capture_run_id: run_id, chunk_index: index) do
      %PoseTraceChunk{payload_digest: ^digest} -> :ok
      %PoseTraceChunk{} -> {:error, :chunk_conflict}
      nil -> {:error, :chunk_conflict}
    end
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

  defp get_user_pose_capture_run(user_id, run_id) do
    Repo.one(
      from(run in PoseCaptureRun,
        where: run.id == ^run_id and run.user_id == ^user_id
      )
    )
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
      from(session in WorkoutSession,
        where: session.user_id == ^user_id and session.status == :reported,
        order_by: [desc: session.inserted_at]
      )
    )
  end

  @spec list_sessions(User.t(), atom) :: [WorkoutSession.t()]
  def list_sessions(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from(session in WorkoutSession,
        where:
          session.user_id == ^user_id and session.status == :reported and
            session.burpee_type == ^burpee_type,
        order_by: [desc: session.inserted_at]
      )
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
        from(s in WorkoutSession,
          where:
            s.user_id == ^user_id and s.status == :reported and
              (is_nil(s.tags) or s.tags != "warmup"),
          select: %{inserted_at: s.inserted_at, duration_sec_actual: s.duration_sec_actual}
        )
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
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and s.status == :reported and
            (is_nil(s.tags) or s.tags != "warmup") and
            s.inserted_at >= ^week_start_dt and
            s.inserted_at <= ^week_end_dt,
        select: s.inserted_at
      )
    )
    |> Enum.map(&DateTime.to_date/1)
    |> MapSet.new()
  end

  @doc """
  Returns the `%WorkoutPlan{}` from the most recent non-warmup session that has
  a plan_id, or `nil` if none exists.
  """
  @spec last_run_plan(User.t()) :: WorkoutPlan.t() | nil
  def last_run_plan(%User{id: user_id}) do
    result =
      Repo.one(
        from(s in WorkoutSession,
          join: p in WorkoutPlan,
          on: p.id == s.plan_id,
          where:
            s.user_id == ^user_id and
              s.status == :reported and
              not is_nil(s.plan_id) and
              (is_nil(s.tags) or s.tags != "warmup"),
          order_by: [desc: s.inserted_at],
          limit: 1,
          select: p
        )
      )

    result
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
      from(s in WorkoutSession,
        where: s.user_id == ^user_id and s.status == :reported,
        order_by: [desc: s.inserted_at],
        limit: ^(limit + 1),
        preload: [:plan, :goal]
      )

    query =
      if before_dt,
        do: where(query, [s], s.inserted_at < ^before_dt),
        else: query

    rows = Repo.all(query)
    has_more = length(rows) > limit
    {Enum.take(rows, limit), has_more}
  end

  @spec get_session!(User.t(), integer) :: WorkoutSession.t()
  def get_session!(%User{id: user_id}, id) do
    Repo.one!(
      from(s in WorkoutSession,
        where: s.user_id == ^user_id and s.id == ^id,
        preload: [:plan, :goal]
      )
    )
  end

  @doc """
  Most recent session for a user + burpee type that has usable baseline data:
  burpee_count_actual > 0 and duration_sec_actual between 1190 and 1210 (20 min ± 10 sec).
  """
  @spec last_session_for_type(User.t(), atom) :: WorkoutSession.t() | nil
  def last_session_for_type(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.one(
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            s.status == :reported and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual >= 1190 and
            s.duration_sec_actual <= 1210,
        order_by: [desc: s.inserted_at],
        limit: 1
      )
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
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            s.status == :reported and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual >= 1190 and
            s.duration_sec_actual <= 1210,
        order_by: [desc: s.burpee_count_actual],
        limit: 1
      )
    )
  end

  @doc """
  All sessions for a user + burpee type suitable for progress charting:
  burpee_count_actual > 0 and duration_sec_actual > 0, ordered oldest first.
  """
  @spec list_sessions_for_chart(User.t(), atom) :: [WorkoutSession.t()]
  def list_sessions_for_chart(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from(s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            s.status == :reported and
            s.burpee_type == ^burpee_type and
            s.burpee_count_actual > 0 and
            s.duration_sec_actual > 0,
        order_by: [asc: s.inserted_at]
      )
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
  Starts a server-derived plan session, idempotent for its client UUID.
  """
  @spec begin_plan_session(User.t(), WorkoutPlan.t(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, term()}
  def begin_plan_session(
        %User{id: user_id},
        %WorkoutPlan{user_id: user_id} = plan,
        client_session_id
      ) do
    with {:ok, planned_attrs} <- planned_session_attrs(plan) do
      %WorkoutSession{user_id: user_id, plan_id: plan.id}
      |> WorkoutSession.start_changeset(
        planned_attrs
        |> Map.put("client_session_id", client_session_id)
        |> Map.put("source", :plan)
      )
      |> Ecto.Changeset.change(
        execution_program_id: Map.fetch!(planned_attrs, "execution_program_id")
      )
      |> begin_session(user_id, :plan, plan.id)
    end
  end

  def begin_plan_session(%User{}, %WorkoutPlan{}, _client_session_id), do: {:error, :not_found}

  @doc """
  Starts a server-derived video session, idempotent for its client UUID.
  """
  @spec begin_video_session(User.t(), WorkoutVideo.t(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, term()}
  def begin_video_session(%User{id: user_id}, %WorkoutVideo{} = video, client_session_id) do
    %WorkoutSession{user_id: user_id, video_id: video.id}
    |> WorkoutSession.start_changeset(%{
      "client_session_id" => client_session_id,
      "source" => :video,
      "burpee_type" => video.burpee_type,
      "burpee_count_planned" => video.burpee_count,
      "duration_sec_planned" => video.duration_sec
    })
    |> begin_session(user_id, :video, video.id)
  end

  @doc """
  Returns one unresolved session, with its source association loaded.
  """
  @spec get_unresolved_session(User.t()) :: WorkoutSession.t() | nil
  def get_unresolved_session(%User{id: user_id}), do: get_unresolved_session_by_user_id(user_id)

  defp get_unresolved_session_by_user_id(user_id) do
    Repo.one(
      from(session in WorkoutSession,
        where: session.user_id == ^user_id and session.status in [:running, :report_pending],
        order_by: [asc: session.inserted_at],
        limit: 1,
        preload: [:plan, :video]
      )
    )
  end

  @doc """
  Marks a running session ready to report. Repeating the transition is safe.
  """
  @spec mark_report_pending(User.t(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, :not_found | :aborted}
  def mark_report_pending(%User{id: user_id}, client_session_id) do
    case get_session_by_client_session_id(user_id, client_session_id) do
      nil ->
        {:error, :not_found}

      %WorkoutSession{status: :running} ->
        now = DateTime.utc_now(:second)

        {count, _} =
          Repo.update_all(
            from(session in WorkoutSession,
              where:
                session.user_id == ^user_id and
                  session.client_session_id == ^client_session_id and
                  session.status == :running
            ),
            set: [status: :report_pending, report_pending_at: now, updated_at: now]
          )

        case count do
          1 -> {:ok, get_session_by_client_session_id(user_id, client_session_id)}
          0 -> resolve_report_pending_transition(user_id, client_session_id)
        end

      %WorkoutSession{status: status} = session when status in [:report_pending, :reported] ->
        {:ok, session}

      %WorkoutSession{status: :aborted} ->
        {:error, :aborted}
    end
  end

  defp resolve_report_pending_transition(user_id, client_session_id) do
    case get_session_by_client_session_id(user_id, client_session_id) do
      %WorkoutSession{status: status} = session when status in [:report_pending, :reported] ->
        {:ok, session}

      %WorkoutSession{status: :aborted} ->
        {:error, :aborted}

      %WorkoutSession{status: :running} ->
        mark_report_pending(%User{id: user_id}, client_session_id)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Reports a running or pending session. A matching replay returns the existing
  row; a different report for the same UUID is rejected without mutation.
  """
  @spec report_session(User.t(), Ecto.UUID.t(), map(), map()) ::
          {:ok, WorkoutSession.t(), :reported | :existing}
          | {:error,
             :not_found | :aborted | :report_conflict | {:unresolved_session, WorkoutSession.t()}}
          | {:error, Ecto.Changeset.t()}
  def report_session(%User{id: user_id}, client_session_id, report_attrs, tracking_attrs)
      when is_map(report_attrs) and is_map(tracking_attrs) do
    case get_session_by_client_session_id(user_id, client_session_id) do
      nil ->
        {:error, :not_found}

      %WorkoutSession{status: :aborted} ->
        {:error, :aborted}

      %WorkoutSession{status: :reported} = session ->
        case report_changeset_with_tracking(session, report_attrs, tracking_attrs) do
          %{valid?: false} = changeset -> {:error, changeset}
          changeset -> replay_report(session, changeset)
        end

      %WorkoutSession{status: status} = session when status in [:running, :report_pending] ->
        report_lifecycle_session(session, user_id, report_attrs, tracking_attrs)
    end
  end

  @doc """
  Aborts a running or pending session. Reported sessions cannot be aborted.
  """
  @spec abort_session(User.t(), Ecto.UUID.t()) ::
          {:ok, WorkoutSession.t()} | {:error, :not_found | :already_reported}
  def abort_session(%User{id: user_id}, client_session_id) do
    case get_session_by_client_session_id(user_id, client_session_id) do
      nil ->
        {:error, :not_found}

      %WorkoutSession{status: status} = session when status in [:running, :report_pending] ->
        abort_lifecycle_session(session, user_id, client_session_id)

      %WorkoutSession{status: :aborted} = session ->
        {:ok, session}

      %WorkoutSession{status: :reported} ->
        {:error, :already_reported}
    end
  end

  @doc """
  Builds a report form changeset without allowing report attrs to replace the
  session's source-derived values.
  """
  @spec change_session_for_report(WorkoutSession.t(), map()) :: Ecto.Changeset.t()
  def change_session_for_report(%WorkoutSession{} = session, attrs \\ %{}) do
    WorkoutSession.report_changeset(session, attrs)
  end

  defp begin_session(changeset, user_id, source, source_id) do
    client_session_id = Ecto.Changeset.get_field(changeset, :client_session_id)

    case get_session_by_client_session_id(user_id, client_session_id) do
      %WorkoutSession{} = session ->
        cond do
          session.source == source and source_reference_matches?(session, source_id) ->
            {:ok, session}

          session.status in [:running, :report_pending] ->
            {:error, {:unresolved_session, session}}

          true ->
            {:error, :not_found}
        end

      nil ->
        case get_unresolved_session_by_user_id(user_id) do
          %WorkoutSession{} = session ->
            {:error, {:unresolved_session, session}}

          nil ->
            insert_started_session(changeset, user_id, source, source_id)
        end
    end
  end

  defp insert_started_session(changeset, user_id, source, source_id) do
    case Repo.insert(changeset) do
      {:ok, session} ->
        {:ok, session}

      {:error, changeset} ->
        case get_session_by_client_session_id(
               user_id,
               Ecto.Changeset.get_field(changeset, :client_session_id)
             ) do
          %WorkoutSession{} = session ->
            if session.source == source and source_reference_matches?(session, source_id) do
              {:ok, session}
            else
              {:error, {:unresolved_session, session}}
            end

          nil ->
            case get_unresolved_session_by_user_id(user_id) do
              %WorkoutSession{} = session -> {:error, {:unresolved_session, session}}
              nil -> {:error, changeset}
            end
        end
    end
  end

  defp source_reference_matches?(%WorkoutSession{source: :plan, plan_id: id}, id), do: true
  defp source_reference_matches?(%WorkoutSession{source: :video, video_id: id}, id), do: true
  defp source_reference_matches?(_session, _source_id), do: false

  defp report_lifecycle_session(session, user_id, report_attrs, tracking_attrs) do
    changeset = report_changeset_with_tracking(session, report_attrs, tracking_attrs)

    if changeset.valid? do
      changeset =
        changeset
        |> Ecto.Changeset.put_change(:report_fingerprint, report_fingerprint(changeset))
        |> with_derived_session_fields(user_id)
        |> maybe_carry_lifecycle_style(session)
        |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now(:second))

      case conditional_session_update(user_id, session.client_session_id, changeset.changes) do
        :updated ->
          reported = get_session_by_client_session_id(user_id, session.client_session_id)
          maybe_upsert_style_performance(reported, user_id)
          {:ok, reported, :reported}

        :not_updated ->
          resolve_report_transition(user_id, session.client_session_id, changeset)
      end
    else
      {:error, changeset}
    end
  end

  defp resolve_report_transition(user_id, client_session_id, changeset) do
    case get_session_by_client_session_id(user_id, client_session_id) do
      %WorkoutSession{status: :reported} = session -> replay_report(session, changeset)
      %WorkoutSession{status: :aborted} -> {:error, :aborted}
      nil -> {:error, :not_found}
      %WorkoutSession{} -> {:error, :report_conflict}
    end
  end

  defp abort_lifecycle_session(session, user_id, client_session_id) do
    changes =
      session
      |> WorkoutSession.abort_changeset()
      |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now(:second))
      |> Map.fetch!(:changes)

    case conditional_session_update(user_id, client_session_id, changes) do
      :updated ->
        {:ok, get_session_by_client_session_id(user_id, client_session_id)}

      :not_updated ->
        case get_session_by_client_session_id(user_id, client_session_id) do
          %WorkoutSession{status: :aborted} = current -> {:ok, current}
          %WorkoutSession{status: :reported} -> {:error, :already_reported}
          nil -> {:error, :not_found}
          %WorkoutSession{} -> {:error, :already_reported}
        end
    end
  end

  defp conditional_session_update(user_id, client_session_id, changes) do
    {count, _} =
      Repo.update_all(
        from(session in WorkoutSession,
          where:
            session.user_id == ^user_id and
              session.client_session_id == ^client_session_id and
              session.status in [:running, :report_pending]
        ),
        set: Map.to_list(changes)
      )

    if count == 1, do: :updated, else: :not_updated
  end

  defp replay_report(session, changeset) do
    if session.report_fingerprint == report_fingerprint(changeset) do
      {:ok, session, :existing}
    else
      {:error, :report_conflict}
    end
  end

  defp report_changeset_with_tracking(session, report_attrs, tracking_attrs) do
    session
    |> WorkoutSession.report_changeset(report_attrs)
    |> apply_report_tracking(session, tracking_attrs)
  end

  defp apply_report_tracking(changeset, %WorkoutSession{source: :plan} = session, tracking_attrs) do
    case report_tracking_mode(changeset, tracking_attrs) do
      {:trusted, cadence} ->
        apply_tracked_session_mode(
          changeset,
          {:trusted, cadence, execution_program_target_pace_sec(session.execution_program_id)},
          session.execution_program_id
        )

      :manual_correction ->
        apply_tracked_session_mode(changeset, :manual_correction, session.execution_program_id)

      :timed ->
        apply_timed_session_mode(changeset)

      :invalid_tracking ->
        Ecto.Changeset.add_error(changeset, :tracking, "must be a finished camera result")
    end
  end

  defp apply_report_tracking(changeset, _session, _tracking_attrs) do
    Ecto.Changeset.change(changeset,
      capture_mode: :logged,
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil
    )
  end

  defp apply_timed_session_mode(changeset) do
    Ecto.Changeset.change(changeset,
      capture_mode: :timed,
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil
    )
  end

  defp report_tracking_mode(changeset, tracking_attrs) do
    if tracking_value(tracking_attrs, :enabled) == true do
      with "finished" <- tracking_value(tracking_attrs, :trust),
           {:ok, detected_reps} <-
             parse_non_negative_integer(tracking_value(tracking_attrs, :detected_reps)),
           {:ok, detected_duration} <-
             parse_non_negative_number(tracking_value(tracking_attrs, :detected_duration_sec)),
           {:ok, actual_reps} <-
             parse_non_negative_integer(Ecto.Changeset.get_field(changeset, :burpee_count_actual)),
           {:ok, actual_duration} <-
             parse_non_negative_number(Ecto.Changeset.get_field(changeset, :duration_sec_actual)) do
        cadence =
          case tracking_value(tracking_attrs, :cadence_ms) do
            value when is_list(value) -> value
            _ -> []
          end

        if actual_reps == detected_reps and actual_duration == detected_duration do
          {:trusted, cadence}
        else
          :manual_correction
        end
      else
        _ -> :invalid_tracking
      end
    else
      :timed
    end
  end

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(_value), do: :error

  defp parse_non_negative_number(value) when is_number(value) and value >= 0, do: {:ok, value}

  defp parse_non_negative_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_number(_value), do: :error

  defp execution_program_target_pace_sec(nil), do: nil

  defp execution_program_target_pace_sec(execution_program_id) do
    case Repo.get(ExecutionProgram, execution_program_id) do
      %ExecutionProgram{} = program ->
        {reps_total, sec_total} =
          program.program_json
          |> tracking_value(:events)
          |> Enum.reduce({0, 0.0}, fn event, {reps_total, sec_total} ->
            case tracking_value(event, :kind) do
              "work" ->
                reps = tracking_value(event, :reps)
                sec_per_rep = tracking_value(event, :sec_per_rep_us) / 1_000_000
                duration_sec = tracking_value(event, :duration_sec) || reps * sec_per_rep
                {reps_total + reps, sec_total + duration_sec}

              _other ->
                {reps_total, sec_total}
            end
          end)

        if reps_total == 0, do: nil, else: Float.round(sec_total / reps_total, 3)

      nil ->
        nil
    end
  end

  defp tracking_value(attrs, key), do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)

  defp report_fingerprint(changeset) do
    [
      burpee_count_actual: Ecto.Changeset.get_field(changeset, :burpee_count_actual),
      duration_sec_actual: Ecto.Changeset.get_field(changeset, :duration_sec_actual),
      note_post: Ecto.Changeset.get_field(changeset, :note_post),
      mood: Ecto.Changeset.get_field(changeset, :mood),
      tags: Ecto.Changeset.get_field(changeset, :tags),
      capture_mode: Ecto.Changeset.get_field(changeset, :capture_mode),
      cadence_ms: Ecto.Changeset.get_field(changeset, :cadence_ms),
      target_pace_sec: Ecto.Changeset.get_field(changeset, :target_pace_sec),
      pace_consistency: Ecto.Changeset.get_field(changeset, :pace_consistency)
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_carry_lifecycle_style(changeset, %WorkoutSession{
         source: :plan,
         plan_id: plan_id,
         user_id: user_id
       }) do
    case Repo.get_by(WorkoutPlan, id: plan_id, user_id: user_id) do
      nil -> changeset
      plan -> maybe_carry_style_name(changeset, plan)
    end
  end

  defp maybe_carry_lifecycle_style(changeset, _session), do: changeset

  @doc """
  Create a session that followed a plan. `user_id` and `plan_id` are
  set programmatically. Derived analytics fields (rate, rolling average,
  days since last, time-of-day bucket) are computed before insert.
  """
  @spec create_session_from_plan(User.t(), WorkoutPlan.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_session_from_plan(%User{id: user_id}, %WorkoutPlan{user_id: user_id} = plan, attrs) do
    with {:ok, planned_attrs} <- planned_session_attrs(plan) do
      attrs =
        attrs
        |> with_client_session_id()
        |> Map.merge(planned_attrs)

      changeset =
        %WorkoutSession{user_id: user_id, plan_id: plan.id}
        |> WorkoutSession.from_plan_changeset(attrs)
        |> Ecto.Changeset.change(
          capture_mode: :timed,
          execution_program_id: Map.fetch!(planned_attrs, "execution_program_id"),
          status: :reported,
          source: :plan,
          reported_at: DateTime.utc_now(:second)
        )
        |> with_derived_session_fields(user_id)
        |> maybe_carry_style_name(plan)

      case insert_idempotent_session(changeset, user_id) do
        {:ok, session, :inserted} ->
          maybe_upsert_style_performance(session, user_id)
          {:ok, session}

        {:ok, session, :existing} ->
          {:ok, session}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def create_session_from_plan(%User{}, %WorkoutPlan{}, _attrs), do: {:error, :not_found}

  @type tracked_session_mode ::
          {:trusted, [non_neg_integer()], number() | String.t() | nil} | :manual_correction

  @spec create_tracked_session_from_plan(User.t(), WorkoutPlan.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_tracked_session_from_plan(%User{} = user, %WorkoutPlan{} = plan, attrs) do
    cadence = Map.get(attrs, "cadence_ms") || Map.get(attrs, :cadence_ms) || []
    target_pace = Map.get(attrs, "target_pace_sec") || Map.get(attrs, :target_pace_sec)
    create_tracked_session_from_plan(user, plan, attrs, {:trusted, cadence, target_pace})
  end

  @spec create_tracked_session_from_plan(
          User.t(),
          WorkoutPlan.t(),
          map,
          tracked_session_mode()
        ) :: {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_tracked_session_from_plan(
        %User{id: user_id},
        %WorkoutPlan{user_id: user_id} = plan,
        attrs,
        tracking_mode
      ) do
    with {:ok, planned_attrs} <- planned_session_attrs(plan) do
      attrs =
        attrs
        |> with_client_session_id()
        |> Map.merge(planned_attrs)

      changeset =
        %WorkoutSession{user_id: user_id, plan_id: plan.id}
        |> WorkoutSession.from_plan_changeset(attrs)
        |> apply_tracked_session_mode(
          tracking_mode,
          Map.fetch!(planned_attrs, "execution_program_id")
        )
        |> Ecto.Changeset.change(
          status: :reported,
          source: :plan,
          reported_at: DateTime.utc_now(:second)
        )
        |> with_derived_session_fields(user_id)
        |> maybe_carry_style_name(plan)

      case insert_idempotent_session(changeset, user_id) do
        {:ok, session, :inserted} ->
          maybe_upsert_style_performance(session, user_id)
          {:ok, session}

        {:ok, session, :existing} ->
          {:ok, session}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def create_tracked_session_from_plan(%User{}, %WorkoutPlan{}, _attrs, _tracking_mode),
    do: {:error, :not_found}

  defp apply_tracked_session_mode(changeset, :manual_correction, execution_program_id) do
    Ecto.Changeset.change(changeset,
      capture_mode: :tracked,
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil,
      execution_program_id: execution_program_id
    )
  end

  defp apply_tracked_session_mode(
         changeset,
         {:trusted, cadence, target_pace},
         execution_program_id
       ) do
    consistency = if valid_cadence_values?(cadence), do: PaceConsistency.score(cadence)

    changeset
    |> validate_tracked_capture(cadence)
    |> Ecto.Changeset.change(
      capture_mode: :tracked,
      cadence_ms: Jason.encode!(cadence),
      target_pace_sec: parse_optional_float(target_pace),
      pace_consistency: consistency,
      execution_program_id: execution_program_id
    )
  end

  defp planned_session_attrs(%WorkoutPlan{} = plan) do
    with {:ok, program} <- compile_plan(plan) do
      {:ok,
       %{
         "burpee_type" => Atom.to_string(program.burpee_type),
         "burpee_count_planned" => program.target_reps,
         "duration_sec_planned" => program.target_duration_sec,
         "execution_program_id" => program.id
       }}
    end
  end

  defp with_client_session_id(attrs) do
    case Map.get(attrs, "client_session_id") || Map.get(attrs, :client_session_id) do
      value when is_binary(value) and value != "" -> attrs
      _ -> Map.put(attrs, "client_session_id", Ecto.UUID.generate())
    end
  end

  defp insert_idempotent_session(changeset, user_id) do
    client_session_id = Ecto.Changeset.get_field(changeset, :client_session_id)

    case get_session_by_client_session_id(user_id, client_session_id) do
      %WorkoutSession{} = session ->
        {:ok, session, :existing}

      nil ->
        case Repo.insert(changeset) do
          {:ok, session} ->
            {:ok, session, :inserted}

          {:error, changeset} ->
            case get_session_by_client_session_id(user_id, client_session_id) do
              %WorkoutSession{} = session -> {:ok, session, :existing}
              nil -> {:error, changeset}
            end
        end
    end
  end

  defp get_session_by_client_session_id(_user_id, nil), do: nil
  defp get_session_by_client_session_id(_user_id, ""), do: nil

  defp get_session_by_client_session_id(user_id, client_session_id) do
    Repo.get_by(WorkoutSession, user_id: user_id, client_session_id: client_session_id)
  end

  @doc """
  Create a free-form session (no plan reference). `user_id` is set
  programmatically. Same derived-field computation as plan sessions.
  """
  @spec create_free_form_session(User.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
  def create_free_form_session(%User{id: user_id}, attrs) do
    changeset =
      %WorkoutSession{user_id: user_id}
      |> WorkoutSession.free_form_changeset(with_client_session_id(attrs))
      |> Ecto.Changeset.change(
        capture_mode: :logged,
        status: :reported,
        source: :manual,
        reported_at: DateTime.utc_now(:second)
      )
      |> with_derived_session_fields(user_id)

    case insert_idempotent_session(changeset, user_id) do
      {:ok, session, _status} -> {:ok, session}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Delete a completed session for a user.

  Linked tracked capture runs are deleted first so stored pose traces are not
  left behind after removing an accidental saved session.
  """
  @spec delete_session(User.t(), integer() | WorkoutSession.t()) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def delete_session(%User{id: user_id} = user, session_id) when is_integer(session_id) do
    case Repo.get_by(WorkoutSession, id: session_id, user_id: user_id) do
      nil -> {:error, :not_found}
      session -> delete_session(user, session)
    end
  end

  def delete_session(%User{id: user_id}, %WorkoutSession{user_id: user_id} = session) do
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

  def delete_session(%User{}, %WorkoutSession{}), do: {:error, :not_found}

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
    Repo.all(from(sp in StylePerformance, where: sp.user_id == ^user_id))
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
      "source_json" => plan_source_attrs(plan),
      "style_name" => plan.style_name,
      "coach_suggestion_kind" => plan.coach_suggestion_kind,
      "coach_target_reps" => plan.coach_target_reps
    }

    create_plan(user, attrs)
  end

  defp plan_source_attrs(%WorkoutPlan{source_json: source}) when is_map(source), do: source
  defp plan_source_attrs(%WorkoutPlan{}), do: nil

  defp normalize_plan_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_metadata_key("plan_solver_metadata")
    |> normalize_metadata_key(:plan_solver_metadata)
  end

  defp normalize_metadata_key(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, metadata} -> Map.put(attrs, key, stringify_metadata(metadata))
      :error -> attrs
    end
  end

  defp stringify_metadata(nil), do: nil

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), stringify_metadata_value(value)} end)
  end

  defp stringify_metadata_value(value) when is_map(value), do: stringify_metadata(value)

  defp stringify_metadata_value(values) when is_list(values),
    do: Enum.map(values, &stringify_metadata_value/1)

  defp stringify_metadata_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> stringify_metadata_value()

  defp stringify_metadata_value(value) when value in [nil, true, false], do: value

  defp stringify_metadata_value(value) when is_atom(value), do: Atom.to_string(value)

  defp stringify_metadata_value(value), do: value

  @doc false
  def preload_plan(%WorkoutPlan{} = plan), do: plan

  # ---------------------------------------------------------------------------
  # Gamification — push-up score, personal bests, milestone detection
  # ---------------------------------------------------------------------------

  @doc """
  Push-up total for the ISO week containing `today` (warmup excluded).
  """
  @spec current_week_pushups(User.t(), Date.t()) :: non_neg_integer
  def current_week_pushups(%User{} = user, today \\ Date.utc_today()) do
    user
    |> scoring_sessions()
    |> Scoring.week_pushups(today)
  end

  @doc """
  Stored gamification bests for a user, with zero/nil defaults when the
  `user_stats` row does not yet exist.
  """
  @spec gamification_stats(User.t()) :: map
  def gamification_stats(%User{id: user_id}), do: read_gamification_stats(user_id)

  @doc """
  Detect and persist the milestones triggered by `session` having just been
  saved. Marks any newly achieved goal, updates personal bests in
  `user_stats`, and returns the ordered list of celebration events (see
  `BurpeeTrainer.Milestones`). Returns `[]` when nothing of note happened.
  """
  @spec session_milestones(User.t(), WorkoutSession.t(), Date.t()) :: [map]
  def session_milestones(user, session, today \\ nil)

  def session_milestones(%User{}, %WorkoutSession{status: status}, _today)
      when status != :reported,
      do: []

  def session_milestones(%User{id: user_id} = user, %WorkoutSession{} = session, today) do
    today = today || DateTime.to_date(session.inserted_at)
    after_sessions = scoring_sessions(user)
    before_sessions = Enum.reject(after_sessions, &(&1.id == session.id))

    week_date = DateTime.to_date(session.inserted_at)
    stats = read_gamification_stats(user_id)

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
      goal: detect_goal(user, session, today),
      days_since_last: session.days_since_last
    }

    events = Milestones.detect(input)

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

    events
  end

  # Detect a goal that this session just achieved for its type. Marks the goal
  # achieved, tags the achieving session, and returns a payload describing how
  # the deadline was met (or nil when no goal was completed).
  defp detect_goal(%User{} = user, %WorkoutSession{burpee_type: type}, today) do
    with goal when not is_nil(goal) <- Goals.get_active_goal(user, type),
         best when not is_nil(best) <- best_qualifying_session(user, type),
         normalized = round(best.burpee_count_actual / best.duration_sec_actual * 1200.0),
         true <- normalized >= goal.burpee_count_target do
      Goals.mark_achieved(goal)
      tag_session_as_goal_reached(best, goal.id)

      %{
        burpee_type: type,
        target: goal.burpee_count_target,
        deadline: deadline_category(today, goal.date_target)
      }
    else
      _ -> nil
    end
  end

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

    Enum.filter(sessions, fn %{inserted_at: dt} ->
      Date.compare(DateTime.to_date(dt) |> Date.beginning_of_week(:monday), week_start) == :eq
    end)
  end

  defp scoring_sessions(%User{id: user_id}) do
    Repo.all(
      from(s in WorkoutSession,
        where: s.user_id == ^user_id and s.status == :reported,
        select: %{
          id: s.id,
          burpee_type: s.burpee_type,
          burpee_count_actual: s.burpee_count_actual,
          duration_sec_actual: s.duration_sec_actual,
          inserted_at: s.inserted_at,
          tags: s.tags
        }
      )
    )
  end

  defp session_map(%WorkoutSession{} = s) do
    %{
      burpee_type: s.burpee_type,
      burpee_count_actual: s.burpee_count_actual,
      duration_sec_actual: s.duration_sec_actual,
      tags: s.tags
    }
  end

  defp read_gamification_stats(user_id) do
    defaults = %{
      best_week_pushups: 0,
      best_session_pushups: 0,
      best_pace_sec_per_burpee: nil,
      lifetime_pushup_milestone: 0
    }

    case Repo.one(
           from(us in "user_stats",
             where: us.user_id == ^user_id,
             select: %{
               best_week_pushups: us.best_week_pushups,
               best_session_pushups: us.best_session_pushups,
               best_pace_sec_per_burpee: us.best_pace_sec_per_burpee,
               lifetime_pushup_milestone: us.lifetime_pushup_milestone
             }
           )
         ) do
      nil -> defaults
      row -> Map.merge(defaults, row)
    end
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
      from(s in WorkoutSession,
        where: s.user_id == ^user_id and s.status == :reported and s.burpee_type == ^burpee_type,
        order_by: [desc: s.inserted_at],
        limit: 1
      )
    )
  end

  defp compute_rate_rolling(_user_id, _burpee_type, nil), do: nil

  defp compute_rate_rolling(user_id, burpee_type, current_rate) do
    prev_rates =
      Repo.all(
        from(s in WorkoutSession,
          where:
            s.user_id == ^user_id and s.status == :reported and
              s.burpee_type == ^burpee_type and not is_nil(s.rate_per_min_actual),
          order_by: [desc: s.inserted_at],
          limit: 2,
          select: s.rate_per_min_actual
        )
      )

    # Oldest first, then current session — EMA gives more weight to recent.
    prev_rates
    |> Enum.reverse()
    |> List.insert_at(-1, current_rate)
    |> ema(0.5)
  end

  defp ema(rates, alpha) do
    case rates do
      [] ->
        nil

      [rate] ->
        rate

      [rate | rest] ->
        Enum.reduce(rest, rate, fn current_rate, acc ->
          alpha * current_rate + (1.0 - alpha) * acc
        end)
    end
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
        from(s in WorkoutSession,
          where: s.user_id == ^user_id and s.status == :reported and s.burpee_type == ^bt,
          select: %{
            burpee_type: s.burpee_type,
            burpee_count_actual: s.burpee_count_actual,
            duration_sec_actual: s.duration_sec_actual
          }
        )
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
