defmodule BurpeeTrainerWeb.ScimJSON do
  @moduledoc "SCIM 2.0 resources, list responses and errors as Pocket ID reads them."

  import Plug.Conn

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Scim.Group

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  def send(conn, status, body) do
    conn
    |> put_resp_content_type("application/scim+json")
    |> send_resp(status, Jason.encode!(body))
  end

  def error(conn, status, detail, scim_type \\ nil) do
    body =
      %{"schemas" => [@error_schema], "status" => Integer.to_string(status), "detail" => detail}
      |> then(&if scim_type, do: Map.put(&1, "scimType", scim_type), else: &1)

    send(conn, status, body)
  end

  def list(%{total: total, start_index: start_index, resources: resources}) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total,
      "startIndex" => start_index,
      "itemsPerPage" => length(resources),
      "Resources" => Enum.map(resources, &resource/1)
    }
  end

  def resource(%User{} = user) do
    %{
      "schemas" => [@user_schema],
      "id" => Integer.to_string(user.id),
      "externalId" => user.oidc_sub,
      "userName" => user.username,
      "active" => user.access == :active,
      "meta" => meta("User", user)
    }
  end

  def resource(%Group{} = group) do
    %{
      "schemas" => [@group_schema],
      "id" => Integer.to_string(group.id),
      "externalId" => group.external_id,
      "displayName" => group.display_name,
      "members" => Enum.map(group.member_ids, &%{"value" => Integer.to_string(&1)}),
      "meta" => meta("Group", group)
    }
  end

  # Pocket ID sends a record only when it changed after `lastModified`; a user never
  # written over SCIM reports none, so Pocket ID writes it on its first sync.
  defp meta(type, record) do
    %{"resourceType" => type, "created" => DateTime.to_iso8601(record.inserted_at)}
    |> then(fn meta ->
      case record.scim_synced_at do
        nil -> meta
        at -> Map.put(meta, "lastModified", DateTime.to_iso8601(at))
      end
    end)
  end
end
