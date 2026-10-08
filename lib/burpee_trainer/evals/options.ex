defmodule BurpeeTrainer.Evals.Options do
  @moduledoc "Fail-closed option parsing for owner-run, explicitly budgeted evaluations."

  def parse!(args) do
    flags =
      args
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

    if length(flags) != length(Enum.uniq(flags)), do: Mix.raise("Duplicate eval options")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [suite: :string, max_calls: :integer, only: :string, record: :boolean]
      )

    if rest != [] or invalid != [] or
         length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))),
       do: Mix.raise("Unknown, duplicate or invalid eval options")

    max_calls = opts[:max_calls]

    if not (is_integer(max_calls) and max_calls > 0),
      do: Mix.raise("--max-calls is required and must be positive")

    suite = Keyword.get(opts, :suite, "authoring")
    if suite != "authoring", do: Mix.raise("Only --suite authoring is supported")
    only = opts[:only]
    if only && not Regex.match?(~r/\A[a-z0-9_]+\z/, only), do: Mix.raise("Invalid scenario ID")
    %{suite: suite, max_calls: max_calls, only: only, record: Keyword.get(opts, :record, false)}
  end
end
