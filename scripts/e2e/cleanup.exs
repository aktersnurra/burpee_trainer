import Ecto.Query

alias BurpeeTrainer.Accounts.User
alias BurpeeTrainer.Repo

alias BurpeeTrainer.Workouts.{
  CoachRecommendation,
  PoseCaptureRun,
  WorkoutPlan,
  WorkoutSession,
  WorkoutVideo
}

if Mix.env() == :prod do
  raise "workout-session E2E cleanup refuses to run in production"
end

fixture = Application.get_env(:burpee_trainer, :adaptive_e2e_fixture, [])
database = Keyword.get(fixture, :database_path)

valid_database? =
  Keyword.get(fixture, :enabled, false) and is_binary(database) and
    Path.dirname(database) == "/tmp" and
    String.starts_with?(Path.basename(database), "adaptive-home-coach-e2e-") and
    String.ends_with?(database, ".db") and Repo.config()[:database] == database

unless valid_database?, do: raise("E2E cleanup requires the disposable adaptive E2E database")

arguments =
  case System.argv() do
    ["--" | rest] -> rest
    arguments -> arguments
  end

case arguments do
  [user_id_text] ->
    case Integer.parse(user_id_text) do
      {user_id, ""} ->
        case Repo.get(User, user_id) do
          nil ->
            IO.puts("E2E_CLEANUP=#{Jason.encode!(%{status: "already_absent", user_id: user_id})}")

          %User{} = user ->
            unless Regex.match?(~r/^e2e_workout_[0-9a-f]{16}$/, user.username) do
              IO.puts(
                :stderr,
                "refusing to delete user #{user_id}: username is not an exact fixture identity"
              )

              System.halt(1)
            end

            owned_video_filename = "e2e-available-#{user.username}.mp4"

            result =
              Repo.immediate_transaction(fn ->
                videos =
                  from(video in WorkoutVideo, where: video.filename == ^owned_video_filename)

                counts = %{
                  videos: Repo.aggregate(videos, :count),
                  plans:
                    Repo.aggregate(
                      from(plan in WorkoutPlan, where: plan.user_id == ^user_id),
                      :count
                    ),
                  drafts:
                    Repo.aggregate(
                      from(plan in WorkoutPlan,
                        where: plan.user_id == ^user_id and plan.state == :draft
                      ),
                      :count
                    ),
                  recommendations:
                    Repo.aggregate(
                      from(recommendation in CoachRecommendation,
                        where: recommendation.user_id == ^user_id
                      ),
                      :count
                    ),
                  sessions:
                    Repo.aggregate(
                      from(session in WorkoutSession, where: session.user_id == ^user_id),
                      :count
                    ),
                  pose_runs:
                    Repo.aggregate(
                      from(run in PoseCaptureRun, where: run.user_id == ^user_id),
                      :count
                    )
                }

                Repo.delete_all(videos)

                trigger_name = "workout_plans_draft_only_delete_trigger"

                [[trigger_sql]] =
                  Repo.query!(
                    "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
                    [trigger_name]
                  ).rows

                Repo.query!("DROP TRIGGER #{trigger_name}")

                if System.get_env("E2E_CLEANUP_INDUCED_FAILURE_AFTER") == "after-trigger-drop" do
                  raise "induced cleanup failure after trigger drop"
                end

                delete_result = Repo.delete(user)
                Repo.query!(trigger_sql)

                case delete_result do
                  {:ok, _user} -> counts
                  {:error, changeset} -> Repo.rollback(changeset)
                end
              end)

            case result do
              {:ok, counts} ->
                IO.puts(
                  "E2E_CLEANUP=" <>
                    Jason.encode!(%{
                      status: "deleted",
                      user_id: user_id,
                      deleted: counts
                    })
                )

              {:error, %Ecto.Changeset{} = changeset} ->
                IO.puts(:stderr, "E2E cleanup failed: #{inspect(changeset.errors)}")
                System.halt(1)

              {:error, reason} ->
                IO.puts(:stderr, "E2E cleanup failed: #{inspect(reason)}")
                System.halt(1)
            end
        end

      _invalid_user_id ->
        IO.puts(:stderr, "user_id must be an integer")
        System.halt(2)
    end

  _arguments ->
    IO.puts(:stderr, "usage: mix run scripts/e2e/cleanup.exs -- USER_ID")
    System.halt(2)
end
