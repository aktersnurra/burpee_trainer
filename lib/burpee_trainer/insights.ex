defmodule BurpeeTrainer.Insights do
  @moduledoc "Scoped storage and reads of completed-session insights."
  import Ecto.Query
  alias BurpeeTrainer.{Repo, UserTime, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.Insights.SessionInsight
  alias BurpeeTrainer.Workouts.WorkoutSession

  def for_session(%Scope{user: user}, session_id) do
    Repo.get_by(SessionInsight, user_id: user.id, session_id: session_id)
  end

  def latest(scope, now \\ DateTime.utc_now(:second))

  def latest(%Scope{user: user}, now) do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, local_start} <-
           UserTime.resolve_local(context.date, ~T[00:00:00], context.timezone),
         {:ok, local_end} <-
           UserTime.resolve_local(Date.add(context.date, 1), ~T[00:00:00], context.timezone),
         {:ok, from} <- DateTime.shift_zone(local_start, "Etc/UTC"),
         {:ok, to} <- DateTime.shift_zone(local_end, "Etc/UTC") do
      Repo.one(
        from i in SessionInsight,
          join: s in WorkoutSession,
          on: s.id == i.session_id and s.user_id == i.user_id,
          where:
            i.user_id == ^user.id and s.state == :completed and
              s.completed_at >= ^from and s.completed_at < ^to and s.completed_at <= ^now,
          order_by: [desc: s.completed_at, desc: s.id],
          limit: 1
      )
    else
      _ -> nil
    end
  end

  @doc false
  def store(
        %Scope{user: user} = scope,
        session_id,
        %{"headline" => headline, "points" => points},
        source
      ) do
    case Workouts.get_session(scope, session_id) do
      %WorkoutSession{} = session ->
        if AuthoritativeSession.authoritative?(session) do
          %SessionInsight{user_id: user.id, session_id: session.id}
          |> SessionInsight.changeset(%{
            headline: headline,
            points: %{"items" => points},
            source: source
          })
          |> Repo.insert(on_conflict: :nothing, conflict_target: :session_id)
          |> case do
            {:ok, _} -> {:ok, for_session(scope, session_id)}
            error -> error
          end
        else
          {:error, :session_not_completed}
        end

      _ ->
        {:error, :session_not_owned}
    end
  end
end
