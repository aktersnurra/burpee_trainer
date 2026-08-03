import Ecto.Query

alias BurpeeTrainer.Repo
alias BurpeeTrainer.Workouts.WorkoutSession

if Mix.env() == :prod do
  raise "workout-session E2E verification refuses to run in production"
end

arguments =
  case System.argv() do
    ["--" | rest] -> rest
    arguments -> arguments
  end

case arguments do
  [user_id_text, client_session_id] ->
    with {user_id, ""} <- Integer.parse(user_id_text),
         true <- Ecto.UUID.cast(client_session_id) == {:ok, client_session_id} do
      sessions =
        Repo.all(
          from(session in WorkoutSession,
            where:
              session.user_id == ^user_id and
                session.client_session_id == ^client_session_id
          )
        )

      case sessions do
        [session] ->
          IO.puts(
            "E2E_VERIFY=" <>
              Jason.encode!(%{
                count: 1,
                session_id: session.id,
                user_id: session.user_id,
                plan_id: session.plan_id,
                client_session_id: session.client_session_id,
                capture_mode: session.capture_mode,
                burpee_count_actual: session.burpee_count_actual,
                duration_sec_actual: session.duration_sec_actual,
                tags: session.tags
              })
          )

        sessions ->
          IO.puts(
            :stderr,
            "Expected exactly one session for the E2E user and client_session_id; " <>
              "found #{length(sessions)}"
          )

          System.halt(1)
      end
    else
      _invalid_arguments ->
        IO.puts(:stderr, "user_id must be an integer and client_session_id must be a UUID")
        System.halt(2)
    end

  _arguments ->
    IO.puts(
      :stderr,
      "usage: mix run scripts/e2e/verify.exs -- USER_ID CLIENT_SESSION_ID"
    )

    System.halt(2)
end
