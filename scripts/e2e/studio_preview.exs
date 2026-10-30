# A real server over a scratch database, with the coach stubbed, for driving the studio in a browser
# (see docs/guides/studio-e2e.md). It runs in the test environment because it uses the test
# fixtures; its database is the one in BURPEE_TRAINER_TEST_DATABASE_PATH, never a real one.
#
#   PREVIEW_DIR=$DIR BURPEE_TRAINER_TEST_DATABASE_PATH=$DIR/e2e.db MIX_ENV=test \
#     mix run --no-start scripts/e2e/studio_preview.exs
#
# It writes $PREVIEW_DIR/preview.json (session cookies for two athletes) and then serves until killed.
scratch = System.fetch_env!("PREVIEW_DIR")
unless System.get_env("BURPEE_TRAINER_TEST_DATABASE_PATH"), do: raise("set BURPEE_TRAINER_TEST_DATABASE_PATH to a scratch database")
ep = Application.get_env(:burpee_trainer, BurpeeTrainerWeb.Endpoint)
Application.put_env(:burpee_trainer, BurpeeTrainerWeb.Endpoint, Keyword.put(ep, :server, true))
{:ok, _} = Application.ensure_all_started(:burpee_trainer)
Ecto.Adapters.SQL.Sandbox.mode(BurpeeTrainer.Repo, :auto)

alias BurpeeTrainer.{Accounts, Workouts}
alias BurpeeTrainer.Accounts.Scope
import BurpeeTrainer.Fixtures

Application.put_env(:burpee_trainer, :llm_provider,
  enabled: true, url: "https://provider.test/v1", api_key: "test", model: "test")

delay = String.to_integer(System.get_env("PREVIEW_DELAY_MS", "1800"))

BurpeeTrainer.ReqStub.default(fn request ->
  body = Jason.decode!(request.body)
  decode = fn content ->
    case Jason.decode(content) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  decoded = Enum.map(body["messages"], &decode.(&1["content"]))
  constraints = Enum.find_value(decoded, fn m -> if m["scope"] == "confirmed_workout_request", do: m["request"] end)
  design = Enum.find_value(decoded, fn m -> if m["scope"] == "workout_design", do: m end) || %{}
  fixed = Enum.find_value(decoded, fn m -> if m["scope"] == "fixed_fields", do: m["request"] end)
  instruction = get_in(design, ["active_attempt", "instruction"]) || ""
  base_reps = get_in(design, ["current_definition", "target_reps"]) || 120

  reps =
    case Regex.run(~r/(\d+) reps/, instruction) do
      [_, n] -> String.to_integer(n)
      _ -> if String.contains?(String.downcase(instruction), "shorter"), do: max(base_reps - 20, 20), else: base_reps
    end

  content =
    cond do
      constraints ->
        Process.sleep(delay)
        r = constraints["target_reps"]
        a = div(r, 2)
        pace = constraints["requested_pace_sec"] || 5
        %{"name" => "Steady #{r}", "rationale" => "Two even sets with a proper breather between them.",
          "phases" => [%{"sets" => [%{"reps" => a, "sec_per_rep" => pace, "sec_per_burpee" => pace}, %{"reps" => r - a, "sec_per_rep" => pace, "sec_per_burpee" => pace}], "rests" => [%{"share" => 1}]}]}

      fixed ->
        Map.merge(fixed, %{"set_reps" => []})

      true ->
        %{"burpee_type" => "six_count", "target_reps" => reps, "target_duration_sec" => 1200,
          "pacing_style" => "unbroken", "recovery" => "required", "requested_pace_sec" => 5,
          "timed_rests" => [], "set_reps" => [div(reps, 2), reps - div(reps, 2)]}
    end

  {request, %Req.Response{status: 200, body: Jason.encode!(%{"choices" => [%{"message" => %{"content" => Jason.encode!(content)}}]})}}
end)

user = user_fixture()
{:ok, user} = Accounts.update_timezone(user, "Etc/UTC")

# History: a few completed sessions so suggestions have something to go on, and a week partly done.
for {type, reps, days} <- [{"six_count", 90, 3}, {"navy_seal", 40, 5}, {"six_count", 100, 1}] do
  free_form_session_fixture(user, %{"burpee_type" => type, "burpee_count_actual" => reps, "duration_sec_actual" => 1200,
    "completed_at" => DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)})
end

for n <- [60, 80, 100, 120] do
  plan_fixture(user, %{"definition" => %{"version" => 1, "name" => "Library #{n}", "burpee_type" => "six_count",
    "target_reps" => n, "target_duration_sec" => 1200, "pacing_style" => "unbroken", "rationale" => "Even sets.",
    "events" => [%{"kind" => "work", "reps" => div(n, 2), "sec_per_rep" => 5, "sec_per_burpee" => 5},
                 %{"kind" => "rest", "duration_sec" => 1200 - n * 5},
                 %{"kind" => "work", "reps" => n - div(n, 2), "sec_per_rep" => 5, "sec_per_burpee" => 5}]}, "state" => "published"})
end

# A second athlete who has trained today, so Home shows its result and the coach.
done_user = user_fixture()
{:ok, done_user} = Accounts.update_timezone(done_user, "Etc/UTC")
for {type, reps, days} <- [{"six_count", 95, 6}, {"six_count", 100, 3}, {"navy_seal", 45, 4}] do
  free_form_session_fixture(done_user, %{"burpee_type" => type, "burpee_count_actual" => reps, "duration_sec_actual" => 1200,
    "completed_at" => DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)})
end
free_form_session_fixture(done_user, %{"burpee_type" => "six_count", "burpee_count_actual" => 104, "duration_sec_actual" => 1200})
{:ok, _} = BurpeeTrainer.Coach.Exchange.record(Scope.for_user(done_user), "My knee felt rough today", "Then keep Thursday light and we'll see how it settles.", ["Make Thursday easier", "Add a rest day"])
{:ok, _} = BurpeeTrainer.Coach.Memory.apply_ops(Scope.for_user(done_user), [%{"op" => "add", "text" => "Left knee gets sore after jumps"}])

# Today's cookie, signed the way the endpoint signs it.
opts = [store: :cookie, key: "_burpee_trainer_key", signing_salt: "LSPz1/8A", same_site: "Lax", http_only: true, secure: true]
secret = Application.get_env(:burpee_trainer, BurpeeTrainerWeb.Endpoint)[:secret_key_base]
conn =
  Plug.Test.conn(:get, "/")
  |> Map.put(:secret_key_base, secret)
  |> Plug.Session.call(Plug.Session.init(opts))
  |> Plug.Conn.fetch_session()
  |> Plug.Conn.put_session(:user_id, user.id)
  |> Plug.Conn.send_resp(200, "")

cookie_for = fn id ->
  Plug.Test.conn(:get, "/")
  |> Map.put(:secret_key_base, secret)
  |> Plug.Session.call(Plug.Session.init(opts))
  |> Plug.Conn.fetch_session()
  |> Plug.Conn.put_session(:user_id, id)
  |> Plug.Conn.send_resp(200, "")
  |> then(& &1.resp_cookies["_burpee_trainer_key"].value)
end

cookie = conn.resp_cookies["_burpee_trainer_key"].value
File.write!(Path.join(scratch, "preview.json"), Jason.encode!(%{cookie: cookie, done_cookie: cookie_for.(done_user.id), port: Application.get_env(:burpee_trainer, BurpeeTrainerWeb.Endpoint)[:http][:port] || 4000, user_id: user.id}))
IO.puts("PREVIEW READY")
Process.sleep(:infinity)
