defmodule BurpeeTrainer.Coach.Memory do
  @moduledoc """
  What the coach remembers about the owner, kept the way the Hermes agent keeps its memory:
  two bounded stores of short entries, `user` (who the athlete is: their schedule, body,
  likes and what they train for; #{1_375} chars) and `memory` (the coach's notes on coaching
  them: what worked, agreements made; #{2_200} chars).

  The coach writes them itself with the memory tool (`Tools.Memory`): add, patch and remove,
  matched by text, checked as one batch by `Memory.Ops`. Each conversation turn reads them as
  a frozen snapshot (`snapshot/1`) taken when it starts; a write lands at once and shows in
  the tool's answer, and in the prompt from the next turn. `MemoryJob` reviews a session's
  feedback, and an exchange where the coach wrote nothing, the same way. The owner sees
  each change as a line in the conversation, and can read and remove entries on Coach.
  Forgotten entries keep their date.
  """
  use Ecto.Schema
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}
  alias BurpeeTrainer.Coach.Memory.Ops

  @type t :: %__MODULE__{}
  schema "coach_notes" do
    field :user_id, :integer
    field :store, :string, default: "user"
    field :text, :string
    field :supersedes_id, :integer
    field :forgotten_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @type change :: %{kind: :noted | :updated | :forgot, text: String.t(), at: DateTime.t()}

  @labels %{
    "user" => "USER PROFILE (who the athlete is)",
    "memory" => "MEMORY (your notes on coaching them)"
  }

  @doc "The owner's entries in both stores, or one store, oldest first."
  @spec list(Scope.t()) :: [t()]
  @spec list(Scope.t(), String.t()) :: [t()]
  def list(%Scope{user: %{id: id}}),
    do:
      Repo.all(
        from n in __MODULE__,
          where: n.user_id == ^id and is_nil(n.forgotten_at),
          order_by: [asc: n.inserted_at, asc: n.id]
      )

  def list(%Scope{} = scope, store), do: scope |> list() |> Enum.filter(&(&1.store == store))

  @doc "Each store's entries and usage, as the owner and Claude read them."
  @spec stores(Scope.t()) :: [
          %{store: String.t(), entries: [t()], usage: String.t(), percent: non_neg_integer()}
        ]
  def stores(%Scope{} = scope) do
    entries = list(scope)

    for store <- Ops.stores() do
      kept = Enum.filter(entries, &(&1.store == store))
      texts = Enum.map(kept, & &1.text)

      %{
        store: store,
        entries: kept,
        usage: Ops.usage(store, texts),
        percent: Ops.percent(store, texts)
      }
    end
  end

  @doc """
  Both stores as the prompt reads them, the way Hermes injects its memory: a header with the
  usage, and the entries separated by `§`. Taken once when a turn starts.
  """
  @spec snapshot(Scope.t()) :: String.t()
  def snapshot(%Scope{} = scope) do
    rule = String.duplicate("═", 46)

    scope
    |> stores()
    |> Enum.map_join("\n\n", fn %{store: store, entries: entries, usage: usage, percent: percent} ->
      body =
        case entries do
          [] -> "(empty)"
          entries -> Enum.map_join(entries, Ops.separator(), & &1.text)
        end

      "#{rule}\n#{@labels[store]} [#{percent}% — #{usage} chars]\n#{rule}\n#{body}"
    end)
  end

  @doc "What was noted, updated or forgotten from `since` on, in order."
  @spec changes_since(Scope.t(), DateTime.t()) :: [change()]
  def changes_since(%Scope{user: %{id: id}}, %DateTime{} = since) do
    rows =
      Repo.all(
        from n in __MODULE__,
          where: n.user_id == ^id and (n.inserted_at >= ^since or n.forgotten_at >= ^since)
      )

    superseded = MapSet.new(for %{supersedes_id: s} <- rows, s, do: s)

    rows
    |> Enum.flat_map(fn note ->
      noted =
        if DateTime.compare(note.inserted_at, since) != :lt,
          do: [
            %{
              kind: if(note.supersedes_id, do: :updated, else: :noted),
              text: note.text,
              at: note.inserted_at
            }
          ],
          else: []

      # A patched entry reads once, as updated; the one it replaced is not also forgotten.
      forgot =
        if forgotten_since?(note, since) and not MapSet.member?(superseded, note.id),
          do: [%{kind: :forgot, text: note.text, at: note.forgotten_at}],
          else: []

      noted ++ forgot
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  defp forgotten_since?(%{forgotten_at: nil}, _since), do: false
  defp forgotten_since?(%{forgotten_at: at}, since), do: DateTime.compare(at, since) != :lt

  @doc """
  Applies a batch of operations to one store (see `Ops.plan/3`) in one transaction and tells
  the owner's screens. Returns the store's live state, or why nothing changed; either is
  what the coach reads back.
  """
  @spec write(Scope.t(), String.t(), term()) :: {:ok, map()} | {:error, map()}
  def write(%Scope{user: %{id: id}} = scope, store, operations) do
    result =
      Repo.immediate_transaction(fn ->
        entries = list(scope, store)

        case Ops.plan(store, Enum.map(entries, &Map.take(&1, [:id, :text])), operations) do
          {:ok, plan} ->
            now = DateTime.utc_now()

            for note <- entries, note.id in plan.forget do
              note |> Ecto.Changeset.change(forgotten_at: now) |> Repo.update!()
            end

            for %{text: text, supersedes: supersedes} <- plan.add do
              Repo.insert!(%__MODULE__{
                user_id: id,
                store: store,
                text: text,
                supersedes_id: supersedes
              })
            end

            {plan.add != [] or plan.forget != [], plan.notes}

          {:error, rejection} ->
            Repo.rollback(rejection)
        end
      end)

    case result do
      {:ok, {changed?, notes}} ->
        if changed?, do: broadcast(scope)
        texts = scope |> list(store) |> Enum.map(& &1.text)

        {:ok,
         %{
           "success" => true,
           "target" => store,
           "changed" => changed?,
           "entries" => texts,
           "usage" => Ops.usage(store, texts)
         }
         |> then(&if(notes == [], do: &1, else: Map.put(&1, "notes", notes)))}

      {:error, %{} = rejection} ->
        {:error, rejection}
    end
  end

  @doc "The owner removes one entry by hand."
  @spec forget(Scope.t(), integer()) :: :ok | {:error, :not_found}
  def forget(%Scope{user: %{id: user_id}} = scope, id) when is_integer(id) do
    query =
      from n in __MODULE__,
        where: n.id == ^id and n.user_id == ^user_id and is_nil(n.forgotten_at)

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      note ->
        note |> Ecto.Changeset.change(forgotten_at: DateTime.utc_now()) |> Repo.update!()
        broadcast(scope)
        :ok
    end
  end

  def forget(_scope, _id), do: {:error, :not_found}

  @doc """
  What to keep and how, for the coach and for Claude; the guidance Hermes gives its agent,
  in a coach's terms.
  """
  @spec guidance() :: String.t()
  def guidance,
    do: """
    You remember the athlete in two parts, shown above as they were when this turn began. \
    USER PROFILE is who they are: when and where they train, their body (injuries, soreness \
    that lingers), what they like and dislike, what they train for, how they want to be \
    coached. MEMORY is your notes on coaching them: what has worked and what has not, what \
    you agreed ("Thursdays stay light until the knee settles"), how they take a hard week. \
    Keep both yourself with the memory tool, without being asked, when you learn something \
    that will still matter next week: a preference, a correction, a change to their \
    schedule or body, an agreement. Skip results (reps, times, levels; they are kept \
    elsewhere), what is only true today, and what is vague. An entry is one dense, specific \
    fact in plain words about the athlete, in the third person, with no internal names \
    (six-count, not six_count). When a fact changes, patch its entry rather than adding \
    another; remove what is no longer true. Each part has a size limit; past 80% full, \
    merge entries in the same batch you add to. Never mention the memory or your notes to \
    the athlete; a coach just remembers.
    """

  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{user: %{id: id}}), do: "coach_memory:#{id}"

  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{} = scope),
    do: Phoenix.PubSub.subscribe(BurpeeTrainer.PubSub, topic(scope))

  defp broadcast(scope),
    do: Phoenix.PubSub.broadcast(BurpeeTrainer.PubSub, topic(scope), :coach_memory)
end
