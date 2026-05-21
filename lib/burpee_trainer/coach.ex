defmodule BurpeeTrainer.Coach do
  @moduledoc """
  Progressive overload coach using Thompson sampling.

  Maintains Beta-distributed arm state in `coach_arms`. Each arm is a
  {burpee_type, dimension, step} triple representing a delta from the
  user's rolling baseline. `suggest/2` samples from all arms and returns
  the highest-scoring arm's configuration. `update_arms/2` attributes a
  completed session to the closest arm and updates its distribution.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach.{Arm, Sampler}
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  @min_sessions 5

  @arm_defs [
    {"baseline", 0.0},
    {"reps", 5.0},
    {"reps", 10.0},
    {"reps", -5.0},
    {"pace", -0.3},
    {"pace", -0.5},
    {"pace", 0.3},
    {"rest", -3.0},
    {"rest", -5.0},
    {"rest", 3.0}
  ]

  @doc """
  Rolling baseline from last #{@min_sessions} non-warmup sessions with a plan of the given type.
  Returns nil if fewer than #{@min_sessions} qualifying sessions exist.
  """
  @spec baseline(User.t(), atom) :: map | nil
  def baseline(%User{id: user_id}, burpee_type) do
    type_str = Atom.to_string(burpee_type)

    sessions =
      Repo.all(
        from s in WorkoutSession,
          join: p in WorkoutPlan,
          on: p.id == s.plan_id,
          where:
            s.user_id == ^user_id and
              s.burpee_type == ^type_str and
              not is_nil(s.plan_id) and
              s.burpee_count_actual > 0 and
              s.duration_sec_actual > 0 and
              (is_nil(s.tags) or s.tags != "warmup"),
          order_by: [desc: s.inserted_at],
          limit: @min_sessions,
          select: %{
            burpee_count: s.burpee_count_actual,
            duration_sec_actual: s.duration_sec_actual,
            burpee_count_actual: s.burpee_count_actual
          }
      )

    if length(sessions) < @min_sessions do
      nil
    else
      count = round(Enum.sum(Enum.map(sessions, & &1.burpee_count)) / length(sessions))

      pace =
        sessions
        |> Enum.map(fn s -> s.duration_sec_actual / s.burpee_count_actual end)
        |> then(fn ps -> Enum.sum(ps) / length(ps) end)

      %{burpee_count: count, sec_per_burpee: pace, rest_sec: 0.0}
    end
  end

  @doc """
  Run Thompson sampling and return the best arm's suggestion, or nil if
  fewer than #{@min_sessions} baseline sessions exist.
  """
  @spec suggest(User.t(), atom) :: map | nil
  def suggest(%User{} = user, burpee_type) do
    base = baseline(user, burpee_type)
    if is_nil(base), do: nil, else: do_suggest(user, burpee_type, base)
  end

  defp do_suggest(%User{id: user_id}, burpee_type, base) do
    type_str = Atom.to_string(burpee_type)
    arms = ensure_arms(user_id, type_str)
    best_idx = Sampler.best_arm(arms)
    best = Enum.at(arms, best_idx)
    apply_arm(base, best.dimension, best.step)
  end

  defp apply_arm(base, "baseline", _step) do
    %{
      burpee_count: base.burpee_count,
      sec_per_burpee: Float.round(base.sec_per_burpee, 1),
      rest_sec: round(base.rest_sec),
      dimension: :baseline,
      rationale: "Confirm your current level — same as recent sessions"
    }
  end

  defp apply_arm(base, "reps", step) do
    count = max(1, base.burpee_count + round(step))
    direction = if step > 0, do: "+#{round(step)} reps", else: "#{round(step)} reps"

    %{
      burpee_count: count,
      sec_per_burpee: Float.round(base.sec_per_burpee, 1),
      rest_sec: round(base.rest_sec),
      dimension: :reps,
      rationale: "Push volume — #{direction} from your recent average of #{base.burpee_count}"
    }
  end

  defp apply_arm(base, "pace", step) do
    pace = Float.round(max(3.5, base.sec_per_burpee + step), 1)
    direction = if step < 0, do: "#{step}s/rep faster", else: "+#{step}s/rep slower"

    %{
      burpee_count: base.burpee_count,
      sec_per_burpee: pace,
      rest_sec: round(base.rest_sec),
      dimension: :pace,
      rationale: "Push intensity — #{direction} than your recent pace of #{Float.round(base.sec_per_burpee, 1)}s/rep"
    }
  end

  defp apply_arm(base, "rest", step) do
    rest = max(0, round(base.rest_sec + step))
    direction = if step < 0, do: "#{round(step)}s shorter rest", else: "+#{round(step)}s rest"

    %{
      burpee_count: base.burpee_count,
      sec_per_burpee: Float.round(base.sec_per_burpee, 1),
      rest_sec: rest,
      dimension: :rest,
      rationale: "Push density — #{direction} between sets"
    }
  end

  @doc """
  After a session is saved, find the arm closest to its parameters and
  update alpha (completion >= 0.8) or beta (completion < 0.8).
  """
  @spec update_arms(User.t(), WorkoutSession.t()) :: :ok
  def update_arms(%User{id: user_id}, %WorkoutSession{} = session) do
    if is_nil(session.plan_id) or is_nil(session.burpee_count_planned) do
      :ok
    else
      type_str = Atom.to_string(session.burpee_type)
      base = baseline(%User{id: user_id}, session.burpee_type)

      if base do
        arms = ensure_arms(user_id, type_str)
        completion = session.burpee_count_actual / max(1, session.burpee_count_planned)
        attributed = find_attributed_arm(arms, base, session)

        if attributed do
          if completion >= 0.8 do
            Repo.update_all(
              from(a in Arm, where: a.id == ^attributed.id),
              inc: [alpha: 1.0]
            )
          else
            Repo.update_all(
              from(a in Arm, where: a.id == ^attributed.id),
              inc: [beta: 1.0]
            )
          end
        end
      end

      :ok
    end
  end

  defp ensure_arms(user_id, type_str) do
    existing =
      Repo.all(
        from a in Arm,
          where: a.user_id == ^user_id and a.burpee_type == ^type_str,
          order_by: [asc: a.dimension, asc: a.step]
      )

    existing_keys = MapSet.new(existing, &{&1.dimension, &1.step})

    missing =
      @arm_defs
      |> Enum.reject(fn {dim, step} -> MapSet.member?(existing_keys, {dim, step}) end)
      |> Enum.map(fn {dim, step} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %{
          user_id: user_id,
          burpee_type: type_str,
          dimension: dim,
          step: step,
          alpha: 1.0,
          beta: 1.0,
          inserted_at: now,
          updated_at: now
        }
      end)

    if missing != [] do
      Repo.insert_all(Arm, missing, on_conflict: :nothing)
    end

    Repo.all(
      from a in Arm,
        where: a.user_id == ^user_id and a.burpee_type == ^type_str,
        order_by: [asc: a.dimension, asc: a.step]
    )
  end

  defp find_attributed_arm(arms, base, session) do
    actual_count = session.burpee_count_actual
    actual_duration = session.duration_sec_actual

    actual_pace =
      if actual_count > 0,
        do: actual_duration / actual_count,
        else: base.sec_per_burpee

    Enum.find(arms, fn arm ->
      suggestion = apply_arm(base, arm.dimension, arm.step)
      count_ok = abs(actual_count - suggestion.burpee_count) <= max(1, round(suggestion.burpee_count * 0.1))
      pace_ok = abs(actual_pace - suggestion.sec_per_burpee) <= 0.5
      count_ok and pace_ok
    end)
  end
end
