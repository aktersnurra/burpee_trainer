defmodule Mix.Tasks.BurpeeTrainer.ExportPoseCorpus do
  @shortdoc "Export recorded camera sessions for replaying the rep counter"

  @moduledoc """
  Writes one `session-<id>.json.gz` per completed camera capture
  (`BurpeeTrainer.Workouts.PoseCorpus`), for

      node assets/js/tools/pose_corpus_report.mjs OUT_DIR
      node assets/js/tools/fit_burpee_hsmm.mjs OUT_DIR assets/js/hooks/fixtures

  ## Usage

      mix burpee_trainer.export_pose_corpus OUT_DIR
      mix burpee_trainer.export_pose_corpus OUT_DIR --database path/to/copy.db

  `--database` reads another SQLite file, such as a copy of the production database.
  Only the Repo starts: no migrations, jobs or endpoint run against it.
  """

  use Mix.Task

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.PoseCorpus

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [database: :string]) do
      {opts, [out_dir], []} -> export(out_dir, opts[:database])
      _ -> Mix.raise("Usage: mix burpee_trainer.export_pose_corpus OUT_DIR [--database PATH]")
    end
  end

  defp export(out_dir, database) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

    config = Application.fetch_env!(:burpee_trainer, Repo)
    config = if database, do: Keyword.put(config, :database, Path.expand(database)), else: config

    unless File.exists?(config[:database]) do
      Mix.raise("No database at #{config[:database]}")
    end

    {:ok, _} = Repo.start_link(Keyword.merge(config, pool_size: 1, log: false))
    paths = PoseCorpus.export(out_dir)
    Mix.shell().info("Exported #{length(paths)} sessions to #{out_dir}")
  end
end
