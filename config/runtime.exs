import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/burpee_trainer start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :burpee_trainer, BurpeeTrainerWeb.Endpoint, server: true
end

endpoint_port = String.to_integer(System.get_env("PORT", "4000"))

config :burpee_trainer, BurpeeTrainerWeb.Endpoint, http: [port: endpoint_port]

adaptive_e2e_fixture? = System.get_env("E2E_ADAPTIVE_FIXTURE") == "1"

if adaptive_e2e_fixture? do
  database_path = System.get_env("E2E_ADAPTIVE_DATABASE_PATH")
  database_prefix = "adaptive-home-coach-e2e-"

  refuse = fn reason ->
    payload =
      Jason.encode!(%{
        reason: reason,
        database_path: database_path,
        application_started: false
      })

    IO.puts(:stderr, "E2E_ADAPTIVE_REFUSED=#{payload}")
    System.halt(4)
  end

  if config_env() == :prod, do: refuse.("production_environment")

  database_basename = if is_binary(database_path), do: Path.basename(database_path)

  resolved_tmp =
    case :file.read_link_all(~c"/tmp") do
      {:ok, target} -> target |> List.to_string() |> Path.expand("/")
      {:error, :einval} -> "/tmp"
      {:error, _reason} -> nil
    end

  resolved_tmp_directory? =
    resolved_tmp in ["/tmp", "/private/tmp"] and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(resolved_tmp)) and
      match?({:error, :einval}, :file.read_link_all(String.to_charlist(resolved_tmp)))

  lexical_path_valid? =
    is_binary(database_path) and is_binary(database_basename) and
      database_path == Path.join("/tmp", database_basename) and
      String.starts_with?(database_basename, database_prefix) and
      String.ends_with?(database_basename, ".db") and
      byte_size(database_basename) > byte_size(database_prefix) + byte_size(".db")

  target_valid? =
    if lexical_path_valid? and resolved_tmp_directory? do
      canonical_target = Path.join(resolved_tmp, database_basename)

      Enum.all?([database_path, canonical_target], fn path ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} -> true
          {:error, :enoent} -> true
          _symlink_or_non_regular -> false
        end
      end)
    else
      false
    end

  unless target_valid?, do: refuse.("invalid_disposable_database_path")

  repo_options =
    [database: database_path, pool_size: 1]
    |> then(fn options ->
      if System.get_env("PHX_SERVER") do
        Keyword.put(options, :pool, DBConnection.ConnectionPool)
      else
        options
      end
    end)

  config :burpee_trainer, BurpeeTrainer.Repo, repo_options

  config :burpee_trainer, BurpeeTrainerWeb.Endpoint,
    url: [host: "127.0.0.1", port: endpoint_port],
    check_origin: ["//127.0.0.1:#{endpoint_port}", "//localhost:#{endpoint_port}"]

  config :burpee_trainer, :llm_provider,
    enabled: false,
    url: nil,
    api_key: nil,
    model: "openai/gpt-5-mini",
    timeout_ms: 20_000

  config :burpee_trainer, :adaptive_e2e_fixture,
    enabled: true,
    database_path: database_path
end

unless adaptive_e2e_fixture? do
  provider_url = System.get_env("LLM_PROVIDER_URL")
  provider_api_key = System.get_env("LLM_PROVIDER_API_KEY")

  timeout_ms =
    case Integer.parse(System.get_env("LLM_PROVIDER_TIMEOUT_MS", "20000")) do
      {value, ""} when value >= 1_000 and value <= 60_000 -> value
      _invalid -> 20_000
    end

  config :burpee_trainer, :llm_provider,
    enabled:
      config_env() != :test and is_binary(provider_url) and provider_url != "" and
        is_binary(provider_api_key) and provider_api_key != "",
    url: provider_url,
    api_key: provider_api_key,
    model: System.get_env("LLM_PROVIDER_MODEL", "openai/gpt-5-mini"),
    timeout_ms: timeout_ms
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/burpee_trainer/burpee_trainer.db
      """

  config :burpee_trainer, BurpeeTrainer.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    journal_mode: :wal,
    cache_size: -64000,
    temp_store: :memory,
    synchronous: :normal

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :burpee_trainer, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :burpee_trainer, BurpeeTrainerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :burpee_trainer, BurpeeTrainerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :burpee_trainer, BurpeeTrainerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :burpee_trainer, BurpeeTrainer.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
