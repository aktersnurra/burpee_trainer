defmodule BurpeeTrainer.Coach.MemoryJob do
  @moduledoc """
  The memory's background review, as the Hermes agent runs one after a turn: after a session
  with feedback, or an exchange in which the coach wrote nothing itself, the model reads the
  memory and what happened and returns memory operations, which `Memory.write/3` applies per
  part, all or nothing. A rejected batch (a part full, a text that matched nothing) goes back
  once with the reason, as the tool would answer the coach. Without a provider nothing
  changes.
  """
  use Oban.Worker, queue: :coach, max_attempts: 1

  require Logger

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Client, Exchange, Memory, SummaryJob}
  alias BurpeeTrainer.Coach.Tools.History
  alias BurpeeTrainer.Workouts.WorkoutSession

  @schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      operations: %{
        type: "array",
        maxItems: 10,
        items: %{
          type: "object",
          additionalProperties: false,
          properties: %{
            target: %{type: "string", enum: ["user", "memory"]},
            action: %{type: "string", enum: ["add", "patch", "remove"]},
            content: %{type: ["string", "null"]},
            old_text: %{type: ["string", "null"]}
          },
          required: ["target", "action", "content", "old_text"]
        }
      }
    },
    required: ["operations"]
  }

  @task """
  Review what just happened with the athlete and keep the coach's memory of them up to \
  date. Return operations, each with its target part: add {content}; patch {old_text, \
  content}; remove {old_text}; leave unused fields null. Most events change nothing; then \
  return no operations. The athlete sees every change.
  """

  @doc "Admits a job for an exchange the owner just had with the coach."
  @spec admit_exchange(Scope.t(), Exchange.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def admit_exchange(%Scope{user: user}, %Exchange{id: id}),
    do: %{"user_id" => user.id, "exchange_id" => id} |> new() |> Oban.insert()

  @doc "Admits a job for a completed session that carries the owner's feedback; else none."
  @spec admit_session(Scope.t(), WorkoutSession.t()) ::
          {:ok, Oban.Job.t()} | :ok | {:error, term()}
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
          event -> scope |> keep(event, []) |> done()
        end
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp done({:ok, _results}), do: :ok
  defp done({:error, reason}), do: {:error, reason}

  # What the coach just learned changes what it would tell the athlete next, so the note
  # on Home is written again from it. A note that cannot be queued is not this job's failure.
  defp refresh_note({:ok, results} = kept, scope) do
    if Enum.any?(results, & &1["changed"]), do: refresh_summary(scope)
    kept
  end

  defp refresh_summary(scope) do
    case SummaryJob.enqueue(scope) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.info(
          "coach_summary_not_admitted trigger=memory user_id=#{scope.user.id} reason=#{inspect(reason)}"
        )
    end
  end

  @doc "Reads one event into the memory; `{:ok, results}` per part written, or why not."
  @spec keep(Scope.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def keep(%Scope{} = scope, event, opts) do
    review(scope, messages(scope, event, []), opts, %{event: event, written: [], retries: 1})
  end

  # The snapshot is taken afresh for each call, so a retry reads the parts already written.
  defp messages(scope, event, retry) do
    [
      %{role: "system", content: @task <> "\n" <> Memory.guidance()},
      %{role: "system", content: Memory.snapshot(scope)},
      %{role: "user", content: Jason.encode!(%{event: event})}
    ] ++ retry
  end

  defp review(scope, messages, opts, state) do
    chat_opts =
      opts
      |> Keyword.take([:config, :req, :budget])
      |> Keyword.merge(
        response_format: {"coach_memory", @schema},
        ledger: %{scope: scope, purpose: "memory", run_id: Ecto.UUID.generate()}
      )

    case Client.chat(messages, chat_opts) do
      {:ok, %{content: %{"operations" => operations} = content, tool_calls: []}}
      when is_list(operations) ->
        case write(scope, operations) do
          {:ok, results} ->
            {:ok, state.written ++ results} |> refresh_note(scope)

          {:error, rejection, written} when state.retries > 0 ->
            # Parts written before the rejection stay written and read in the new snapshot;
            # only the rejected part is asked for again.
            retry = [
              %{role: "assistant", content: Jason.encode!(content)},
              %{
                role: "user",
                content:
                  Jason.encode!(%{
                    rejected: rejection,
                    already_written: Enum.map(written, & &1["target"]),
                    ask:
                      "The parts already written are saved and shown above. Send operations for #{rejection["target"]} only."
                  })
              }
            ]

            review(scope, messages(scope, state.event, retry), opts, %{
              state
              | written: state.written ++ written,
                retries: state.retries - 1
            })

          {:error, rejection, written} ->
            refresh_note({:ok, state.written ++ written}, scope)
            {:error, {:rejected, rejection}}
        end

      {:ok, _other} ->
        {:error, :invalid_shape}

      {:error, reason} ->
        Logger.info("coach_memory_unchanged user_id=#{scope.user.id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  # One batch per part, in the order the parts first appear; a rejected part stops there,
  # and says which parts were written before it.
  defp write(scope, operations) do
    operations = Enum.filter(operations, &is_map/1)
    targets = operations |> Enum.map(& &1["target"]) |> Enum.uniq()

    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, results} ->
      ops =
        for %{"target" => ^target} = op <- operations do
          op |> Map.drop(["target"]) |> Map.reject(fn {_key, value} -> is_nil(value) end)
        end

      case Memory.write(scope, target, ops) do
        {:ok, result} ->
          {:cont, {:ok, results ++ [result]}}

        {:error, rejection} ->
          {:halt, {:error, Map.put(rejection, "target", target), results}}
      end
    end)
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
