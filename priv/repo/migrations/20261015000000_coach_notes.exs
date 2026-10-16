defmodule BurpeeTrainer.Repo.Migrations.CoachNotes do
  use Ecto.Migration

  # The coach's memory becomes one short note per fact, kept by the coach after each
  # exchange and session. A forgotten note stays, dated, so the conversation can say so.
  # Each notebook line becomes a note, dated when the notebook was last written, so old
  # notes do not read as newly noted; list marks and heading lines ("…:") are dropped.
  def up do
    create table(:coach_notes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :forgotten_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:coach_notes, [:user_id, :forgotten_at])
    flush()

    %{rows: rows} = repo().query!("SELECT user_id, body, updated_at FROM coach_notebooks")

    for [user_id, body, written_at] <- rows,
        line <- String.split(body || "", ["\n", "\r"], trim: true),
        text =
          line
          |> String.trim()
          |> String.trim_leading("-")
          |> String.trim_leading("*")
          |> String.trim(),
        text != "" and not String.ends_with?(text, ":") do
      repo().query!(
        "INSERT INTO coach_notes (user_id, text, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
        [user_id, String.slice(text, 0, 160), written_at, written_at]
      )
    end

    drop table(:coach_notebooks)
  end

  def down do
    create table(:coach_notebooks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false, default: ""
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_notebooks, [:user_id])
    drop table(:coach_notes)
  end
end
