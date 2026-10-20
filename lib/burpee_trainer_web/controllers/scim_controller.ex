defmodule BurpeeTrainerWeb.ScimController do
  @moduledoc """
  `/scim/v2/Users` and `/scim/v2/Groups` for Pocket ID's SCIM sync (see
  `BurpeeTrainer.Scim`). A user who loses access has their open pages closed at once.
  """
  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainer.Scim
  alias BurpeeTrainerWeb.{Auth, ScimJSON}

  @max_count 1000

  def index(conn, params) do
    {start_index, count} = paging(params)

    page =
      case conn.assigns.resource do
        :users -> Scim.list_users(start_index, count)
        :groups -> Scim.list_groups(start_index, count)
      end

    ScimJSON.send(conn, 200, ScimJSON.list(page))
  end

  def show(conn, %{"id" => id}) do
    case get(conn.assigns.resource, id) do
      nil -> not_found(conn)
      resource -> ScimJSON.send(conn, 200, ScimJSON.resource(resource))
    end
  end

  def create(conn, params) do
    conn.assigns.resource
    |> create_resource(params)
    |> respond(conn, 201)
  end

  def update(conn, %{"id" => id} = params) do
    conn.assigns.resource
    |> replace(id, params)
    |> respond(conn, 200)
  end

  def delete(conn, %{"id" => id}) do
    case delete_resource(conn.assigns.resource, id) do
      {:ok, _deleted} -> send_resp(conn, 204, "")
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp get(:users, id), do: Scim.get_user(id)
  defp get(:groups, id), do: Scim.get_group(id)

  defp create_resource(:users, params), do: Scim.create_user(params) |> closing_pages()
  defp create_resource(:groups, params), do: Scim.create_group(params)

  defp replace(:users, id, params), do: Scim.replace_user(id, params) |> closing_pages()
  defp replace(:groups, id, params), do: Scim.replace_group(id, params)

  defp delete_resource(:users, id), do: Scim.remove_user(id) |> closing_pages()
  defp delete_resource(:groups, id), do: Scim.delete_group(id)

  # A user without access is signed out of the pages they have open.
  defp closing_pages({:ok, %{access: :active}} = result), do: result

  defp closing_pages({:ok, user} = result) do
    Auth.disconnect_user(user)
    result
  end

  defp closing_pages(error), do: error

  defp respond({:ok, resource}, conn, status),
    do: ScimJSON.send(conn, status, ScimJSON.resource(resource))

  defp respond({:error, :not_found}, conn, _status), do: not_found(conn)

  defp respond({:error, :conflict}, conn, _status),
    do: ScimJSON.error(conn, 409, "The username belongs to another identity", "uniqueness")

  defp respond({:error, _invalid}, conn, _status),
    do: ScimJSON.error(conn, 400, "Invalid resource", "invalidValue")

  defp not_found(conn), do: ScimJSON.error(conn, 404, "Resource not found")

  # SCIM counts from 1; Pocket ID pages 1,000 at a time.
  defp paging(params) do
    {positive(params["startIndex"], 1), min(positive(params["count"], @max_count), @max_count)}
  end

  defp positive(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 1 -> n
      _ -> default
    end
  end
end
