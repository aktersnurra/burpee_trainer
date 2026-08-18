if Mix.env() == :prod do
  raise "workout-session E2E setup refuses to run in production"
end

System.put_env("E2E_LIBRARY_SETUP_ONLY", "1")
Code.require_file(Path.expand("library_setup.exs", __DIR__))

options = [
  run_id:
    System.get_env("E2E_RUN_ID") ||
      System.system_time(:millisecond) |> Integer.to_string(36),
  base_url: System.get_env("E2E_BASE_URL") || "http://127.0.0.1:4000"
]

options =
  case System.get_env("E2E_PASSWORD") do
    password when is_binary(password) and password != "" ->
      Keyword.put(options, :password, password)

    _missing ->
      options
  end

case BurpeeTrainer.E2E.LibrarySetup.run("started-plan-session", options) do
  {:ok, setup} ->
    IO.puts("E2E_SETUP=#{Jason.encode!(setup)}")

  {:error, reason} ->
    IO.puts(:stderr, "E2E setup failed: #{inspect(reason)}")
    System.halt(1)
end
