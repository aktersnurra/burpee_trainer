defmodule BurpeeTrainer.Coach.Context do
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.{DesignSession, DesignEntry, Memory}
  alias BurpeeTrainer.Workouts.Error
  @kinds [:initial_context, :baseline, :instruction, :proposal, :outcome]

  def home_key(expected),
    do: "home:#{expected.recommendation_id}:#{expected.home_revision}"

  def ensure_session(user, source, key) do
    safe(fn ->
      with :ok <- authorized_source(user, source) do
        if source && source.state == :draft && source.design_session_id do
          owned_session(user, source.design_session_id)
        else
          key = if source && source.state == :draft, do: "draft:#{source.id}", else: key
          initialize(user, source, key)
        end
      end
    end)
  end

  defp initialize(user, source, key) when is_binary(key) and byte_size(key) in 1..200 do
    Repo.immediate_transaction(fn ->
      now = DateTime.utc_now()
      source_id = source && source.id

      {inserted, _} =
        Repo.insert_all(
          DesignSession,
          [%{user_id: user.id, workspace_key: key, source_plan_id: source_id, inserted_at: now}],
          on_conflict: :nothing,
          conflict_target: [:user_id, :workspace_key]
        )

      session = Repo.get_by!(DesignSession, user_id: user.id, workspace_key: key)

      if session.source_plan_id != source_id,
        do: Repo.rollback(Error.new(:design_workspace_changed))

      if inserted == 1 do
        attempt = Ecto.UUID.generate()

        insert_or_rollback(user, session.id, attempt, :initial_context, %{
          "global_context" => Memory.global_context(user)
        })

        insert_or_rollback(user, session.id, attempt, :baseline, baseline(user, source))
      end

      session
    end)
  end

  defp initialize(_user, _source, _key), do: {:error, Error.new(:design_workspace_changed)}

  def append(user, session_id, attempt, kind, payload) do
    safe(fn ->
      with {:ok, _} <- owned_session(user, session_id),
           {:ok, ^attempt} <- Ecto.UUID.cast(attempt),
           true <- kind in @kinds and is_map(payload) do
        %DesignEntry{
          design_session_id: session_id,
          attempt_id: attempt,
          kind: kind,
          payload: payload
        }
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint([:design_session_id, :attempt_id, :kind])
        |> Repo.insert()
        |> case do
          {:ok, entry} -> {:ok, entry}
          {:error, _} -> {:error, Error.new(:design_log_failed)}
        end
      else
        {:error, %Error{} = error} -> {:error, error}
        _ -> {:error, Error.new(:design_log_failed)}
      end
    end)
  end

  def entries(user, session_id) do
    safe(fn ->
      with {:ok, _} <- owned_session(user, session_id) do
        {:ok,
         Repo.all(
           from(e in DesignEntry,
             where: e.design_session_id == ^session_id,
             order_by: [asc: e.id]
           )
         )}
      end
    end)
  end

  def messages(user, session_id, source, attempt, prompt, extra_messages \\ []) do
    safe(fn ->
      with :ok <- check_source(user, session_id, source),
           {:ok, _session} <- owned_session(user, session_id),
           {:ok, entries} <- entries(user, session_id),
           %DesignEntry{} = active <-
             Enum.find(
               entries,
               &(&1.attempt_id == attempt and &1.kind == :instruction)
             ) do
        request_entries =
          Enum.filter(entries, &(&1.kind in [:initial_context, :baseline] or &1.id == active.id))

        messages =
          [
            %{role: "system", content: prompt},
            %{
              role: "system",
              content:
                Jason.encode!(%{
                  scope: "global",
                  context: Memory.global_context(user),
                  rule: "Local workout instructions are not enduring global preferences."
                })
            },
            %{
              role: "user",
              content:
                Jason.encode!(%{
                  scope: "workout_design",
                  active_attempt: %{id: attempt, instruction: active.payload["text"]},
                  rule: "Act only on active_attempt; prior failed proposals are not examples.",
                  current_definition: source && source.definition_json,
                  entries: Enum.map(request_entries, &request_entry_payload/1)
                })
            }
          ] ++ extra_messages

        if byte_size(Jason.encode!(messages)) <= 262_144,
          do: {:ok, messages},
          else: {:error, Error.new(:authoring_context_too_large)}
      else
        {:error, %Error{} = error} -> {:error, error}
        _ -> {:error, Error.new(:design_attempt_not_found)}
      end
    end)
  end

  def check_source(user, id, source) do
    safe(fn ->
      with :ok <- authorized_source(user, source),
           {:ok, session} <- owned_session(user, id) do
        valid =
          cond do
            source == nil ->
              session.source_plan_id == nil

            source.state == :draft and source.user_id == user.id and
                source.design_session_id == id ->
              true

            true ->
              session.source_plan_id == source.id
          end

        if valid, do: :ok, else: {:error, Error.new(:design_workspace_changed)}
      end
    end)
  end

  def check_home_workspace(user, id, expected) do
    safe(fn ->
      with :ok <- check_source(user, id, expected.plan),
           {:ok, session} <- owned_session(user, id) do
        if (expected.plan != nil and expected.plan.state == :draft) or
             session.workspace_key == home_key(expected),
           do: :ok,
           else: {:error, Error.new(:design_workspace_changed)}
      end
    end)
  end

  defp owned_session(user, id) do
    case Repo.get_by(DesignSession, id: id, user_id: user.id) do
      nil -> {:error, Error.new(:design_session_not_owned)}
      session -> {:ok, session}
    end
  end

  defp authorized_source(_user, nil), do: :ok

  defp authorized_source(user, source) do
    with {:ok, current} <- Workouts.design_source(user, source.id),
         true <-
           current.updated_at == source.updated_at and
             current.content_hash == source.content_hash do
      :ok
    else
      _ -> {:error, Error.new(:source_unavailable)}
    end
  end

  defp baseline(_user, nil), do: %{"imported" => true, "source" => nil}

  defp baseline(user, source) do
    public = %{
      "imported" => true,
      "source_plan_id" => source.id,
      "definition" => source.definition_json,
      "program" => source.program_json
    }

    if source.user_id == user.id do
      prior =
        case source.design_session_id do
          nil ->
            []

          id ->
            case entries(user, id) do
              {:ok, values} -> Enum.map(values, &entry_payload/1)
              {:error, error} -> Repo.rollback(error)
            end
        end

      Map.merge(public, %{"request_text" => source.request_text, "prior_owned_entries" => prior})
    else
      public
    end
  end

  defp entry_payload(e),
    do: %{id: e.id, attempt_id: e.attempt_id, kind: Atom.to_string(e.kind), payload: e.payload}

  defp request_entry_payload(%DesignEntry{kind: :baseline} = entry) do
    entry
    |> entry_payload()
    |> update_in([:payload], &Map.delete(&1, "prior_owned_entries"))
  end

  defp request_entry_payload(entry), do: entry_payload(entry)

  defp insert_or_rollback(user, id, attempt, kind, payload) do
    case append(user, id, attempt, kind, payload) do
      {:ok, entry} -> entry
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, Error.new(:design_context_unavailable)}
  catch
    :exit, _ -> {:error, Error.new(:design_context_unavailable)}
  end
end
