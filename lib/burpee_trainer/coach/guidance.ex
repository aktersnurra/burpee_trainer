defmodule BurpeeTrainer.Coach.Guidance do
  @moduledoc "User-owned coach instructions; the original text remains durable before LLM review."

  import Ecto.Query

  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Coach.{Client, GuidanceEntry}

  @max_text_length 1_000
  @max_summary_length 280
  @context_limit 12
  @review_kinds ~w[lasting temporary observation]

  @spec add(Accounts.Scope.t(), String.t()) ::
          {:ok, GuidanceEntry.t()} | {:error, :invalid_text}
  def add(%Accounts.Scope{user: %Accounts.User{id: user_id}}, text) when is_binary(text) do
    text = String.trim(text)

    if text == "" or String.length(text) > @max_text_length do
      {:error, :invalid_text}
    else
      %GuidanceEntry{user_id: user_id, text: text}
      |> Repo.insert()
    end
  end

  def add(%Accounts.Scope{}, _text), do: {:error, :invalid_text}

  @spec update(Accounts.Scope.t(), integer(), String.t()) ::
          {:ok, GuidanceEntry.t()} | {:error, :invalid_text | :not_found}
  def update(%Accounts.Scope{user: %Accounts.User{id: user_id}}, id, text)
      when is_integer(id) and is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" or String.length(text) > @max_text_length ->
        {:error, :invalid_text}

      true ->
        case Repo.get_by(GuidanceEntry, id: id, user_id: user_id) do
          nil ->
            {:error, :not_found}

          %GuidanceEntry{text: ^text} = entry ->
            {:ok, entry}

          entry ->
            entry
            |> Ecto.Changeset.change(text: text, kind: "pending", summary: nil)
            |> Repo.update()
        end
    end
  end

  def update(%Accounts.Scope{}, _id, _text), do: {:error, :not_found}

  @spec list(Accounts.Scope.t()) :: [GuidanceEntry.t()]
  def list(%Accounts.Scope{user: %Accounts.User{id: user_id}}) do
    Repo.all(from(e in GuidanceEntry, where: e.user_id == ^user_id, order_by: [desc: e.id]))
  end

  @spec remove(Accounts.Scope.t(), integer()) :: :ok | {:error, :not_found}
  def remove(%Accounts.Scope{user: %Accounts.User{id: user_id}}, id) when is_integer(id) do
    {deleted, _} =
      Repo.delete_all(from(e in GuidanceEntry, where: e.user_id == ^user_id and e.id == ^id))

    if deleted == 1, do: :ok, else: {:error, :not_found}
  end

  def remove(%Accounts.Scope{}, _id), do: {:error, :not_found}

  @spec context(Accounts.Scope.t()) :: %{pending: [map()], lasting: [map()], temporary: [map()]}
  def context(%Accounts.Scope{user: %Accounts.User{id: user_id}}) do
    entries =
      Repo.all(
        from(e in GuidanceEntry,
          where: e.user_id == ^user_id and e.kind in ["pending", "lasting", "temporary"],
          order_by: [desc: e.id],
          limit: @context_limit
        )
      )

    %{
      pending: for(e <- entries, e.kind == "pending", do: %{id: e.id, text: e.text}),
      lasting: for(e <- entries, e.kind == "lasting", do: %{id: e.id, summary: e.summary}),
      temporary: for(e <- entries, e.kind == "temporary", do: %{id: e.id, summary: e.summary})
    }
  end

  @spec start_review(GuidanceEntry.t()) :: {:ok, pid()} | {:error, term()}
  def start_review(%GuidanceEntry{id: id}) do
    Task.Supervisor.start_child(BurpeeTrainer.CoachMemoryTaskSupervisor, fn ->
      _ = review(id)
    end)
  end

  @spec review(integer(), keyword()) ::
          {:ok, GuidanceEntry.t()} | {:error, term()}
  def review(id, opts \\ [])

  def review(id, opts) when is_integer(id) do
    case Repo.get(GuidanceEntry, id) do
      nil ->
        {:error, :not_found}

      %GuidanceEntry{kind: "pending"} = entry ->
        complete = Keyword.get(opts, :complete, &Client.complete/2)

        with {:ok, reply} <- complete.(review_messages(entry), response_kind: :coach_guidance),
             {:ok, kind, summary} <- validate_review(reply) do
          {updated, _} =
            Repo.update_all(
              from(e in GuidanceEntry,
                where:
                  e.id == ^id and e.kind == "pending" and e.text == ^entry.text and
                    e.updated_at == ^entry.updated_at
              ),
              set: [kind: kind, summary: summary, updated_at: DateTime.utc_now()]
            )

          case Repo.get(GuidanceEntry, id) do
            nil -> {:error, :not_found}
            _ when updated == 0 -> {:error, :stale_review}
            reviewed -> {:ok, reviewed}
          end
        end

      entry ->
        {:ok, entry}
    end
  end

  def review(_id, _opts), do: {:error, :not_found}

  defp review_messages(entry) do
    [
      %{
        role: "system",
        content:
          "Classify the user's coaching instruction. lasting = an enduring goal or preference; temporary = a short-lived next-session context; observation = not a coaching instruction. Summarize only what the user stated. Never infer medical conditions or invent training facts."
      },
      %{role: "user", content: entry.text}
    ]
  end

  defp validate_review(%{"kind" => kind, "summary" => summary})
       when kind in @review_kinds and is_binary(summary) do
    summary = String.trim(summary)

    if summary != "" and String.length(summary) <= @max_summary_length,
      do: {:ok, kind, summary},
      else: {:error, :invalid_review}
  end

  defp validate_review(_), do: {:error, :invalid_review}
end
