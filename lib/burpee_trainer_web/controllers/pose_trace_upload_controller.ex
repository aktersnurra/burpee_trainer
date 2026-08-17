defmodule BurpeeTrainerWeb.PoseTraceUploadController do
  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainerWeb.CoreComponents

  def create(
        conn,
        %{"client_session_id" => client_session_id, "chunks" => chunks} = params
      ) do
    complete? = params["complete"] == true

    case Workouts.ingest_pose_trace_batch(
           conn.assigns.current_user,
           client_session_id,
           chunks,
           complete?
         ) do
      {:ok, result} ->
        json(conn, result)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:error, :chunk_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "chunk_conflict"})

      {:error, :invalid_batch} ->
        invalid_batch(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          changeset
          |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
          |> Map.new(fn {field, messages} -> {Atom.to_string(field), messages} end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end

  def create(conn, _params), do: invalid_batch(conn)

  defp invalid_batch(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{batch: ["is invalid"]}})
  end
end
