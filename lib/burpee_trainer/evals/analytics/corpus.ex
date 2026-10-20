defmodule BurpeeTrainer.Evals.Analytics.Corpus do
  @moduledoc "Versioned hand-derived fixtures; held-out means excluded from tuning, not secret."
  @root Path.expand("../../../../test/fixtures/analytics", __DIR__)
  @external_resource Path.join(@root, "cases.json")
  @cases Jason.decode!(File.read!(@external_resource))
  @datasets (for name <- ~w(spring autumn), into: %{} do
               path = Path.join(@root, name <> ".json")
               @external_resource path
               {name, Jason.decode!(File.read!(path))}
             end)

  def version, do: 1

  def cases do
    Enum.map(@cases, fn c ->
      %{
        id: c["id"],
        dataset: c["dataset"],
        partition: if(c["partition"] == "held_out", do: :held_out, else: :development),
        prompt: c["prompt"],
        expected: c["expected"],
        comparison: c["comparison"],
        rationale: c["rationale"],
        category: c["category"],
        oracle_sql: c["oracle_sql"]
      }
    end)
  end

  def datasets, do: Enum.map(~w(spring autumn), &dataset/1)
  def dataset(id), do: Map.fetch!(@datasets, id)

  def now(dataset) do
    {:ok, now, _} = DateTime.from_iso8601(dataset["now"])
    now
  end

  @doc "Exact fixture preflight ignoring database-assigned session IDs; never imports or writes history."
  def matches?(snapshot, dataset) do
    snapshot.timezone == dataset["timezone"] and
      Enum.sort(Enum.map(snapshot.rows, &tl/1)) == Enum.sort(Enum.map(dataset["rows"], &tl/1))
  end
end
