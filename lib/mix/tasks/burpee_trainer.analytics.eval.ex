defmodule Mix.Tasks.BurpeeTrainer.Analytics.Eval do
  @shortdoc "Offline analytics protocol report; live requires explicit owner and paid-call opt-in"
  @moduledoc "Usage: mix burpee_trainer.analytics.eval [--dataset spring|autumn] [--partition development|held_out] [--live --owner-opt-in --max-calls N --user-id ID --dataset NAME]. JSON goes to stdout; contains sensitive owner evidence on live runs."
  use Mix.Task
  alias BurpeeTrainer.Evals.Analytics.{Corpus, Runner}

  @impl true
  def run(args) do
    opts = parse!(args)

    cases =
      Enum.filter(Corpus.cases(), fn c ->
        (is_nil(opts.dataset) or c.dataset == opts.dataset) and
          (is_nil(opts.partition) or Atom.to_string(c.partition) == opts.partition)
      end)

    scope = scope(opts)

    result =
      Runner.run(scope, cases,
        mode: opts.mode,
        owner_opt_in: opts.owner_opt_in,
        max_calls: opts.max_calls
      )

    case result do
      {:ok, report} ->
        Mix.shell().info(Jason.encode!(report, pretty: true))

      {:error, %{report: report}} ->
        Mix.shell().info(Jason.encode!(report, pretty: true))
        Mix.raise("Comparison halted; inspect report accounting/fixture error")

      {:error, reason} ->
        Mix.raise("Evaluation refused: #{reason}")
    end
  end

  def parse!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          live: :boolean,
          owner_opt_in: :boolean,
          max_calls: :integer,
          user_id: :integer,
          dataset: :string,
          partition: :string
        ]
      )

    flags =
      Enum.filter(args, &String.starts_with?(&1, "--"))
      |> Enum.map(&(String.split(&1, "=", parts: 2) |> hd()))

    if rest != [] or invalid != [] or length(flags) != length(Enum.uniq(flags)),
      do: Mix.raise(@moduledoc)

    member!(opts[:dataset], ~w(spring autumn))
    member!(opts[:partition], ~w(development held_out))
    live = opts[:live] == true
    live_options!(live, opts)

    %{
      mode: if(live, do: :live, else: :offline),
      owner_opt_in: live,
      max_calls: opts[:max_calls] || 0,
      user_id: opts[:user_id],
      dataset: opts[:dataset],
      partition: opts[:partition]
    }
  end

  defp member!(nil, _), do: :ok

  defp member!(value, allowed) do
    unless value in allowed, do: Mix.raise(@moduledoc)
  end

  defp live_options!(true, opts) do
    unless opts[:owner_opt_in] == true and positive?(opts[:max_calls]) and
             positive?(opts[:user_id]) and not is_nil(opts[:dataset]), do: Mix.raise(@moduledoc)
  end

  defp live_options!(false, opts) do
    if Enum.any?([:owner_opt_in, :max_calls, :user_id], &Keyword.has_key?(opts, &1)),
      do: Mix.raise("Paid/owner options require --live; offline never contacts providers")
  end

  defp positive?(value), do: is_integer(value) and value > 0

  defp scope(%{mode: :offline}), do: nil

  defp scope(opts) do
    Mix.Task.run("app.start")
    user = BurpeeTrainer.Repo.get!(BurpeeTrainer.Accounts.User, opts.user_id)
    BurpeeTrainer.Accounts.Scope.for_user(user)
  end
end
