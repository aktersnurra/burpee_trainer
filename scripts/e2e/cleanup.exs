import Ecto.Query

alias BurpeeTrainer.Accounts.User
alias BurpeeTrainer.Repo
alias BurpeeTrainer.Workouts.{PoseCaptureRun, WorkoutPlan, WorkoutSession}

if Mix.env() == :prod do
  raise "workout-session E2E cleanup refuses to run in production"
end

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

          %User{username: "e2e_workout_" <> _suffix} = user ->
            counts = %{
              plans:
                Repo.aggregate(from(plan in WorkoutPlan, where: plan.user_id == ^user_id), :count),
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

            case Repo.delete(user) do
              {:ok, _user} ->
                IO.puts(
                  "E2E_CLEANUP=" <>
                    Jason.encode!(%{
                      status: "deleted",
                      user_id: user_id,
                      deleted: counts
                    })
                )

              {:error, changeset} ->
                IO.puts(:stderr, "E2E cleanup failed: #{inspect(changeset.errors)}")
                System.halt(1)
            end

          %User{} ->
            IO.puts(
              :stderr,
              "refusing to delete user #{user_id}: username lacks e2e_workout_ prefix"
            )

            System.halt(1)
        end

      _invalid_user_id ->
        IO.puts(:stderr, "user_id must be an integer")
        System.halt(2)
    end

  _arguments ->
    IO.puts(:stderr, "usage: mix run scripts/e2e/cleanup.exs -- USER_ID")
    System.halt(2)
end
