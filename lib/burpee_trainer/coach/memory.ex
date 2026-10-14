defmodule BurpeeTrainer.Coach.Memory do
  @moduledoc """
  What the coach knows about the owner: one short note per fact. The coach keeps it itself
  after each exchange and session (`Coach.MemoryJob`); the owner sees what changed as a
  line in the conversation and corrects it by saying so. Forgotten notes keep their date.
  """
  use Ecto.Schema
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}
  alias BurpeeTrainer.Coach.Memory.Ops

  @type t :: %__MODULE__{}
  schema "coach_notes" do
    field :user_id, :integer
    field :text, :string
    field :forgotten_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @type change :: %{kind: :noted | :forgot, text: String.t(), at: DateTime.t()}

  @doc "The owner's notes, oldest first."
  @spec list(Scope.t()) :: [t()]
  def list(%Scope{user: %{id: id}}),
    do:
      Repo.all(
        from n in __MODULE__,
          where: n.user_id == ^id and is_nil(n.forgotten_at),
          order_by: [asc: n.inserted_at, asc: n.id]
      )

  @doc "What was noted or forgotten from `since` on, in order."
  @spec changes_since(Scope.t(), DateTime.t()) :: [change()]
  def changes_since(%Scope{user: %{id: id}}, %DateTime{} = since) do
    from(n in __MODULE__,
      where: n.user_id == ^id and (n.inserted_at >= ^since or n.forgotten_at >= ^since)
    )
    |> Repo.all()
    |> Enum.flat_map(fn note ->
      noted =
        if DateTime.compare(note.inserted_at, since) != :lt,
          do: [%{kind: :noted, text: note.text, at: note.inserted_at}],
          else: []

      forgot =
        if note.forgotten_at && DateTime.compare(note.forgotten_at, since) != :lt,
          do: [%{kind: :forgot, text: note.text, at: note.forgotten_at}],
          else: []

      noted ++ forgot
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc """
  Applies the coach's ops (see `Ops.plan/2`) in one transaction and tells the owner's
  screens. Returns what changed.
  """
  @spec apply_ops(Scope.t(), [map()]) :: {:ok, [change()]} | {:error, term()}
  def apply_ops(%Scope{user: %{id: id}} = scope, ops) do
    result =
      Repo.immediate_transaction(fn ->
        notes = list(scope)
        %{add: add, forget: forget} = Ops.plan(Enum.map(notes, &Map.take(&1, [:id, :text])), ops)
        now = DateTime.utc_now()

        forgot =
          for note <- notes, note.id in forget do
            note |> Ecto.Changeset.change(forgotten_at: now) |> Repo.update!()
            %{kind: :forgot, text: note.text, at: now}
          end

        noted =
          for text <- add do
            Repo.insert!(%__MODULE__{user_id: id, text: text})
            %{kind: :noted, text: text, at: now}
          end

        forgot ++ noted
      end)

    with {:ok, changes} <- result do
      if changes != [], do: broadcast(scope)
      {:ok, changes}
    end
  end

  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{user: %{id: id}}), do: "coach_memory:#{id}"

  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{} = scope),
    do: Phoenix.PubSub.subscribe(BurpeeTrainer.PubSub, topic(scope))

  defp broadcast(scope),
    do: Phoenix.PubSub.broadcast(BurpeeTrainer.PubSub, topic(scope), :coach_memory)
end
