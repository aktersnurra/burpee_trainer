defmodule BurpeeTrainer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BurpeeTrainerWeb.Telemetry,
        BurpeeTrainer.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:burpee_trainer, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:burpee_trainer, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: BurpeeTrainer.PubSub}
      ] ++
        oidc_children() ++
        [BurpeeTrainerWeb.Endpoint]

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

  # The provider-configuration worker performs OIDC discovery against the
  # issuer shortly after boot. Skipped when OIDC is unconfigured (a
  # half-configured dev machine still boots) and in test, where the issuer
  # is unreachable and the worker's default `stop` backoff would terminate
  # the supervision tree.
  defp oidc_children do
    start? = Application.get_env(:burpee_trainer, :oidc_start_worker, true)

    if start? and BurpeeTrainer.Auth.Oidc.configured?() do
      cfg = Application.fetch_env!(:burpee_trainer, :oidc)

      [
        {Oidcc.ProviderConfiguration.Worker,
         %{issuer: cfg[:issuer], name: BurpeeTrainer.Auth.Oidc.provider_name()}}
      ]
    else
      []
    end
  end
end
