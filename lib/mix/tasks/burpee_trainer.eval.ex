defmodule Mix.Tasks.BurpeeTrainer.Eval do
  @shortdoc "Evaluate authoring with a mandatory --max-calls budget (owner-run only)"
  use Mix.Task
  alias BurpeeTrainer.Evals.{Options, Runner}

  @impl Mix.Task
  def run(args) do
    options = Options.parse!(args)
    Mix.Task.run("app.start")
    result = Runner.run(options)

    Enum.each(result.scenarios, fn row ->
      Mix.shell().info(
        "#{row.id}: success=#{row.success} calls=#{row.calls} repaired=#{row.repaired} failure=#{row.failure_reason || "none"}"
      )
    end)

    Mix.shell().info("Measured calls: #{result.total.calls}; results: #{result.output_path}")
  end
end
