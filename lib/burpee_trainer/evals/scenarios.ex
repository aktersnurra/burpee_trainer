defmodule BurpeeTrainer.Evals.Scenarios do
  @moduledoc "Owner eval inputs translated through the same controls as Home authoring."
  alias BurpeeTrainerWeb.HomeWorkoutRequest

  def load!("authoring", only) do
    scenarios =
      Path.wildcard("priv/evals/authoring/*.json")
      |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)
      |> Enum.filter(&(is_nil(only) or &1["id"] == only))

    if scenarios == [], do: Mix.raise("No matching eval scenarios")
    scenarios
  end

  def prepare(%{"form" => form}) when is_map(form) do
    changeset = HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, form)

    with {:ok, params} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, request} <- HomeWorkoutRequest.request(params) do
      {:ok, %{request: request, instruction: HomeWorkoutRequest.instruction(params)}}
    else
      _ -> {:error, :invalid_form}
    end
  end

  def prepare(_), do: {:error, :invalid_form}
end
