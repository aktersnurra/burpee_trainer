alias BurpeeTrainer.{Accounts, Repo, Workouts}

if Mix.env() == :prod do
  raise "workout-session E2E setup refuses to run in production"
end

run_id =
  System.get_env("E2E_RUN_ID") ||
    System.system_time(:millisecond) |> Integer.to_string(36)

safe_run_id =
  run_id
  |> String.replace(~r/[^a-zA-Z0-9_.-]/, "-")
  |> String.slice(0, 16)

username = System.get_env("E2E_USERNAME") || "e2e_workout_#{safe_run_id}"

password =
  System.get_env("E2E_PASSWORD") ||
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

base_url = System.get_env("E2E_BASE_URL") || "http://127.0.0.1:4000"

source_json = %{
  "burpee_type" => "six_count",
  "target_duration_sec" => 60,
  "target_reps" => 3,
  "pacing_style" => "even",
  "load_shape" => "even",
  "pace_bias" => "balanced",
  "explicit_rests" => [],
  "block_pattern" => nil
}

result =
  Repo.transaction(fn ->
    with {:ok, user} <-
           Accounts.register_user(%{"username" => username, "password" => password}),
         {:ok, plan} <-
           Workouts.create_plan(user, %{
             "name" => "Workout session E2E",
             "source_json" => source_json
           }) do
      %{
        user_id: user.id,
        username: username,
        password: password,
        plan_id: plan.id,
        base_url: base_url,
        login_url: "#{base_url}/login",
        session_url: "#{base_url}/session/#{plan.id}"
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end)

case result do
  {:ok, setup} ->
    IO.puts("E2E_SETUP=#{Jason.encode!(setup)}")

  {:error, reason} ->
    IO.puts(:stderr, "E2E setup failed: #{inspect(reason)}")
    System.halt(1)
end
