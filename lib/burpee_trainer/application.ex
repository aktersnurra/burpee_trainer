defmodule BurpeeTrainer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    warn_if_highs_missing()

    children = [
      BurpeeTrainerWeb.Telemetry,
      BurpeeTrainer.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:burpee_trainer, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:burpee_trainer, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BurpeeTrainer.PubSub},
      # Start a worker by calling: BurpeeTrainer.Worker.start_link(arg)
      # {BurpeeTrainer.Worker, arg},
      # Start to serve requests, typically the last entry
      BurpeeTrainerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BurpeeTrainer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BurpeeTrainerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp warn_if_highs_missing do
    path = Application.get_env(:burpee_trainer, :highs_path, "highs")

    if System.find_executable(path) == nil do
      require Logger

      Logger.warning(
        "HiGHS solver not found on PATH (looked for #{inspect(path)}). " <>
          "Plan generation will fail until HiGHS is installed."
      )
    end
  end
end
