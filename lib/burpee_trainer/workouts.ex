defmodule BurpeeTrainer.Workouts do
  @moduledoc """
  Context for workout plans (with blocks + sets) and workout sessions.
  All queries are scoped by `user_id`.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.{Block, WorkoutPlan, WorkoutSession}

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
      "warmup_enabled" => source.warmup_enabled,
      "warmup_reps" => source.warmup_reps,
      "warmup_rounds" => source.warmup_rounds,
      "rest_sec_warmup_between" => source.rest_sec_warmup_between,
      "rest_sec_warmup_before_main" => source.rest_sec_warmup_before_main,
      "shave_off_sec" => source.shave_off_sec,
      "shave_off_block_count" => source.shave_off_block_count,
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
  List the last `count` sessions of a given type for a user, most
  recent first. Used by the progression trend calculation.
  """
  @spec list_recent_sessions(User.t(), atom, pos_integer) :: [WorkoutSession.t()]
  def list_recent_sessions(%User{id: user_id}, burpee_type, count)
      when is_atom(burpee_type) and is_integer(count) and count > 0 do
    Repo.all(
      from session in WorkoutSession,
        where: session.user_id == ^user_id and session.burpee_type == ^burpee_type,
        order_by: [desc: session.inserted_at],
        limit: ^count
    )
  end

  @doc """
  Create a session that followed a plan. `user_id` and `plan_id` are
  set programmatically.
  """
  @spec create_session_from_plan(User.t(), WorkoutPlan.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
  def create_session_from_plan(%User{id: user_id}, %WorkoutPlan{id: plan_id}, attrs) do
    %WorkoutSession{user_id: user_id, plan_id: plan_id}
    |> WorkoutSession.from_plan_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a free-form session (no plan reference). `user_id` is set
  programmatically.
  """
  @spec create_free_form_session(User.t(), map) ::
          {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
  def create_free_form_session(%User{id: user_id}, attrs) do
    %WorkoutSession{user_id: user_id}
    |> WorkoutSession.free_form_changeset(attrs)
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
end
