defmodule BurpeeTrainer.Coach.MemoryJob do
  @moduledoc """
  Keeps the coach's memory after an exchange or a session with feedback: the model reads
  the notes and what just happened, and says what to note, forget or replace. Its ops go
  through `Memory.apply_ops/2`, so a careless answer cannot wipe or bloat the memory.
  Without a provider nothing changes.
  """
  use Oban.Worker, queue: :coach, max_attempts: 1

  require Logger

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Accounts.{Scope, User}
  alias BurpeeTrainer.Coach.{Client, Exchange, Memory}
  alias BurpeeTrainer.Coach.Tools.History
  alias BurpeeTrainer.Workouts.WorkoutSession

  @schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      ops: %{
        type: "array",
        maxItems: 5,
        items: %{
          type: "object",
          additionalProperties: false,
          properties: %{
            op: %{type: "string", enum: ["add", "forget", "replace"]},
            id: %{type: ["integer", "null"]},
            text: %{type: ["string", "null"], maxLength: 160}
          },
          required: ["op", "id", "text"]
        }
      }
    },
    required: ["ops"]
  }

  @task """
  You keep short notes about an athlete for their burpee coach: lasting facts and \
  preferences that should shape future training, such as when they train, injuries or \
  soreness, what they like or dislike, and what they are training for. Read the notes and \
  the event, and return ops: add a new fact; forget a note the event shows is no longer \
  true; replace a note the event updates. Each note is one plain sentence under 160 \
  characters, about the athlete, in the third person without a name. Do not note results \
  (reps, times, levels), which are kept elsewhere, or anything only true today. Most \
  events change nothing; then return no ops. The athlete reads every change.
  """

  @doc """
  Admits a job for an exchange the owner just had with the coach. The MCP client keeps
  the memory of a user it coaches (`update_memory`), so no job is admitted for them.
  """
  @spec admit_exchange(Scope.t(), Exchange.t()) :: {:ok, Oban.Job.t()} | :ok | {:error, term()}
  def admit_exchange(%Scope{user: %User{coach: :mcp}}, %Exchange{}), do: :ok

  def admit_exchange(%Scope{user: user}, %Exchange{id: id}),
    do: %{"user_id" => user.id, "exchange_id" => id} |> new() |> Oban.insert()

  @doc "Admits a job for a completed session that carries the owner's feedback; else none."
  @spec admit_session(Scope.t(), WorkoutSession.t()) ::
          {:ok, Oban.Job.t()} | :ok | {:error, term()}
  def admit_session(%Scope{user: %User{coach: :mcp}}, %WorkoutSession{}), do: :ok

  def admit_session(%Scope{user: user}, %WorkoutSession{id: id} = session) do
    if feedback?(session),
      do: %{"user_id" => user.id, "session_id" => id} |> new() |> Oban.insert(),
      else: :ok
  end

  defp feedback?(session),
    do:
      Enum.any?(
        [session.note_pre, session.note_post, session.tags],
        &(is_binary(&1) and String.trim(&1) != "")
      ) or
        not is_nil(session.mood) or not is_nil(session.primary_limiter) or
        not is_nil(session.preference_feedback)

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) when is_integer(user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        {:cancel, :user_missing}

      user ->
        scope = Scope.for_user(user)

        case event(scope, args) do
          nil -> {:cancel, :event_missing}
          event -> keep(scope, event, [])
        end
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  @doc "Reads one event into the memory; `{:ok, changes}`, or the reason nothing changed."
  @spec keep(Scope.t(), map(), keyword()) :: {:ok, [Memory.change()]} | {:error, term()}
  def keep(%Scope{} = scope, event, opts) do
    notes = Memory.list(scope)

    messages = [
      %{role: "system", content: @task},
      %{
        role: "user",
        content:
          Jason.encode!(%{
            notes: Enum.map(notes, &%{id: &1.id, text: &1.text}),
            event: event
          })
      }
    ]

    chat_opts =
      opts
      |> Keyword.take([:config, :req, :budget])
      |> Keyword.merge(
        response_format: {"coach_memory", @schema},
        ledger: %{scope: scope, purpose: "memory", run_id: Ecto.UUID.generate()}
      )

    case Client.chat(messages, chat_opts) do
      {:ok, %{content: %{"ops" => ops}, tool_calls: []}} when is_list(ops) ->
        Memory.apply_ops(scope, ops)

      {:ok, _other} ->
        {:error, :invalid_shape}

      {:error, reason} ->
        Logger.info("coach_memory_unchanged user_id=#{scope.user.id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp event(scope, %{"exchange_id" => id}) when is_integer(id) do
    case Repo.get_by(Exchange, id: id, user_id: scope.user.id) do
      nil -> nil
      exchange -> %{kind: "conversation", athlete: exchange.message, coach: exchange.reply}
    end
  end

  defp event(scope, %{"session_id" => id}) when is_integer(id) do
    case Workouts.get_session(scope, id) do
      %WorkoutSession{state: :completed} = session ->
        session
        |> History.summary()
        |> Map.merge(%{
          "kind" => "session",
          "note_before" => session.note_pre,
          "note_after" => session.note_post,
          "tags" => session.tags
        })

      _ ->
        nil
    end
  end

  defp event(_scope, _args), do: nil
end
