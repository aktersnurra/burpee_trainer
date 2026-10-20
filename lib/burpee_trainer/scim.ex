defmodule BurpeeTrainer.Scim do
  @moduledoc """
  Users and groups as Pocket ID provisions them over SCIM 2.0. Pocket ID v2.16 lists
  `/Users` and `/Groups`, then creates (`POST`), replaces (`PUT`) and deletes (`DELETE`)
  them; it matches its own records by `externalId`, its user id, which is the `sub` the
  app stores as `oidc_sub`.

  - A user's `active` is their access: `:active`, or `:disabled` while blocked in
    Pocket ID. Deleting a user marks them `:removed` and keeps their data; Pocket ID
    creating them again restores them.
  - Membership of the coach group (`config :burpee_trainer, :scim, coach_group:`, its
    Pocket ID id) decides `users.coach`: members `:app`, everyone else `:mcp`. Until that
    group is provisioned, coaches are left as they are.
  - Each write stamps `scim_synced_at`, reported as `meta.lastModified`: Pocket ID only
    sends a record changed after it.
  """

  import Ecto.Query

  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Scim.Group

  @type page(t) :: %{total: non_neg_integer(), start_index: pos_integer(), resources: [t]}

  @doc "Whether provisioning is on: a token is configured."
  @spec token() :: {:token, String.t()} | :off
  def token do
    case config()[:token] do
      token when is_binary(token) and token != "" -> {:token, token}
      _ -> :off
    end
  end

  @doc "The Pocket ID group whose members the app's coach runs for."
  @spec coach_group() :: {:group, String.t()} | :none
  def coach_group do
    case config()[:coach_group] do
      id when is_binary(id) and id != "" -> {:group, id}
      _ -> :none
    end
  end

  defp config, do: Application.get_env(:burpee_trainer, :scim, [])

  # Users ----------------------------------------------------------------------------

  # Only users Pocket ID knows (a `sub`) and has not removed are provisioned resources.
  defp provisioned_users,
    do: from(u in User, where: not is_nil(u.oidc_sub) and u.access != :removed)

  @spec list_users(pos_integer(), non_neg_integer()) :: page(User.t())
  def list_users(start_index, count), do: page(provisioned_users(), start_index, count)

  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id), do: with_id(id, &Repo.get(provisioned_users(), &1))

  @doc """
  Creates the user, or takes over the one already linked to the `sub` (a removed user is
  restored) or holding the username unlinked, as sign-in would.
  """
  @spec create_user(map()) ::
          {:ok, User.t()} | {:error, :conflict | :invalid | Ecto.Changeset.t()}
  def create_user(%{"externalId" => sub, "userName" => username} = attrs)
      when is_binary(sub) and is_binary(username) do
    case Accounts.resolve_oidc_identity(sub, username) do
      {:ok, user} -> write_user(user, attrs)
      {:error, :sub_conflict} -> {:error, :conflict}
      {:error, :username_missing} -> {:error, :invalid}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  def create_user(_attrs), do: {:error, :invalid}

  @doc "Replaces what Pocket ID owns of the user: their access, and their coach."
  @spec replace_user(String.t(), map()) :: {:ok, User.t()} | {:error, :not_found}
  def replace_user(id, attrs) when is_map(attrs) do
    case get_user(id) do
      %User{} = user -> write_user(user, attrs)
      nil -> {:error, :not_found}
    end
  end

  @doc "The user lost access to the app: marked removed, never deleted."
  @spec remove_user(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def remove_user(id) do
    case get_user(id) do
      %User{} = user -> stamp(user, access: :removed)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Pocket ID let the user sign in, so they have access now; their coach follows the coach
  group. Not a SCIM write: Pocket ID's own changes still reach the app.
  """
  @spec signed_in(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def signed_in(%User{} = user) do
    changes =
      Keyword.reject([access: :active, coach: coach_for(user)], &match?({_, :unchanged}, &1))

    user |> Ecto.Changeset.change(changes) |> Repo.update()
  end

  defp write_user(user, attrs),
    do: stamp(user, access: access(attrs), coach: coach_for(user))

  defp access(%{"active" => false}), do: :disabled
  defp access(_attrs), do: :active

  defp stamp(user, changes) do
    changes = Keyword.reject(changes, &match?({_, :unchanged}, &1))

    user
    |> Ecto.Changeset.change([{:scim_synced_at, now()} | changes])
    |> Repo.update()
  end

  @doc """
  The user's coach by the coach group: `:app` for a member, else `:mcp`; `:unchanged`
  until the group is configured and provisioned.
  """
  @spec coach_for(User.t()) :: User.coach() | :unchanged
  def coach_for(%User{id: id}) do
    case stored_coach_group() do
      %Group{member_ids: members} -> member_coach(id in members)
      nil -> :unchanged
    end
  end

  defp member_coach(true), do: :app
  defp member_coach(false), do: :mcp

  defp stored_coach_group do
    case coach_group() do
      {:group, external_id} -> Repo.get_by(Group, external_id: external_id)
      :none -> nil
    end
  end

  # Groups ---------------------------------------------------------------------------

  @spec list_groups(pos_integer(), non_neg_integer()) :: page(Group.t())
  def list_groups(start_index, count), do: page(Group, start_index, count)

  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(id), do: with_id(id, &Repo.get(Group, &1))

  @doc "Creates the group, or replaces the one with the same Pocket ID id."
  @spec create_group(map()) :: {:ok, Group.t()} | {:error, :invalid}
  def create_group(%{"externalId" => external_id} = attrs) when is_binary(external_id) do
    (Repo.get_by(Group, external_id: external_id) || %Group{external_id: external_id})
    |> write_group(attrs)
  end

  def create_group(_attrs), do: {:error, :invalid}

  @spec replace_group(String.t(), map()) :: {:ok, Group.t()} | {:error, :not_found | :invalid}
  def replace_group(id, attrs) do
    case get_group(id) do
      %Group{} = group -> write_group(group, attrs)
      nil -> {:error, :not_found}
    end
  end

  @spec delete_group(String.t()) :: {:ok, Group.t()} | {:error, :not_found}
  def delete_group(id) do
    case get_group(id) do
      %Group{} = group ->
        Repo.transaction(fn ->
          deleted = Repo.delete!(group)
          follow_coach_group(deleted.external_id, [])
          deleted
        end)

      nil ->
        {:error, :not_found}
    end
  end

  defp write_group(group, %{"displayName" => name} = attrs) when is_binary(name) do
    members = attrs |> Map.get("members", []) |> member_ids()

    Repo.transaction(fn ->
      written =
        group
        |> Ecto.Changeset.change(display_name: name, member_ids: members, scim_synced_at: now())
        |> Repo.insert_or_update!()

      follow_coach_group(written.external_id, members)
      written
    end)
  end

  defp write_group(_group, _attrs), do: {:error, :invalid}

  # A member is the app's own user id, as `/Users` gave it.
  defp member_ids(members) when is_list(members) do
    for %{"value" => value} <- members,
        {id, ""} <- [Integer.parse(to_string(value))],
        uniq: true,
        do: id
  end

  defp member_ids(_members), do: []

  # The coach group's members get the app's coach; everyone else coaches over MCP.
  defp follow_coach_group(external_id, members) do
    case coach_group() do
      {:group, ^external_id} ->
        Repo.update_all(from(u in User, where: u.id in ^members), set: [coach: :app])
        Repo.update_all(from(u in User, where: u.id not in ^members), set: [coach: :mcp])

      _other_group ->
        :ok
    end
  end

  # Shared ---------------------------------------------------------------------------

  defp page(queryable, start_index, count) do
    query = from(r in queryable, order_by: r.id)

    %{
      total: Repo.aggregate(query, :count),
      start_index: start_index,
      resources: query |> offset(^(start_index - 1)) |> limit(^count) |> Repo.all()
    }
  end

  defp with_id(id, fun) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> fun.(id)
      _ -> nil
    end
  end

  defp now, do: DateTime.utc_now(:second)
end
