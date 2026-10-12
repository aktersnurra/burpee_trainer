defmodule BurpeeTrainer.Coach.Tools.UpdateNotebook do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Tool, Notebook, Voice}
  def name, do: "update_notebook"

  def description,
    do:
      "Replace the notes the athlete reads under Coach's notes: lasting facts and preferences in the voice above, max 4000 characters."

  def schema, do: Tool.object(%{"text" => %{"type" => "string", "maxLength" => 4000}}, ["text"])

  def call(scope, %{"text" => text} = args, %{notebook_seen: seen})
      when is_binary(text) and map_size(args) == 1 do
    case Voice.internal_id(text) do
      nil -> write(scope, text, seen)
      id -> {:error, "the athlete reads this notebook; write #{id} in plain words"}
    end
  end

  def call(_, _, _), do: {:error, "invalid notebook arguments"}

  defp write(scope, text, seen) do
    case Notebook.write(scope, text, seen) do
      {:ok, nb} ->
        {:ok, %{"saved" => true}, %{notebook_seen: nb.updated_at}}

      {:error, :too_long} ->
        {:error, "text exceeds 4000 characters"}

      {:error, :stale_notebook} ->
        {:error, "the owner edited the notebook during this run; keep their version"}
    end
  end
end
