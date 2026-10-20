defmodule Mix.Tasks.BurpeeTrainer.Analytics.Trace do
  @shortdoc "Print one explicitly requested sensitive owner trace"
  @moduledoc "Usage: mix burpee_trainer.analytics.trace --user-id ID --trace-id UUID"
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user_id: :integer, trace_id: :string])

    unless rest == [] and invalid == [] and is_integer(opts[:user_id]) and
             is_binary(opts[:trace_id]),
           do: Mix.raise(@moduledoc)

    Mix.Task.run("app.start")
    user = BurpeeTrainer.Repo.get!(BurpeeTrainer.Accounts.User, opts[:user_id])
    scope = BurpeeTrainer.Accounts.Scope.for_user(user)

    case BurpeeTrainer.Analytics.Trace.fetch(scope, opts[:trace_id]) do
      {:ok, payload} -> Mix.shell().info(Jason.encode!(payload, pretty: true))
      {:error, _} -> Mix.raise("Trace not found")
    end
  end
end
