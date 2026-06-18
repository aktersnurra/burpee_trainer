defmodule BurpeeTrainer.Workouts.SessionLogTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.SessionLog

  describe "to_attrs/5" do
    test "normalizes free-form log params for persistence" do
      params = %{
        "burpee_count_actual" => "100",
        "duration_sec_actual" => "20",
        "log_date" => "2026-06-01",
        "note_post" => "felt good"
      }

      assert %{
               "burpee_type" => "navy_seal",
               "mood" => "1",
               "tags" => "hot,tired",
               "duration_sec_actual" => "1200",
               "inserted_at" => inserted_at,
               "note_post" => "felt good"
             } = SessionLog.to_attrs(params, :navy_seal, 1, ["tired", "hot"], ~D[2026-06-01])

      assert inserted_at == ~U[2026-06-01 12:00:00Z]
    end

    test "preserves invalid duration text for changeset validation" do
      params = %{"duration_sec_actual" => "bad"}

      attrs = SessionLog.to_attrs(params, :six_count, 0, [], ~D[2026-06-01])

      assert attrs["duration_sec_actual"] == "bad"
    end
  end

  describe "parse_log_date/2" do
    test "parses ISO date and falls back to current date" do
      assert SessionLog.parse_log_date(%{"log_date" => "2026-06-02"}, ~D[2026-06-01]) ==
               ~D[2026-06-02]

      assert SessionLog.parse_log_date(%{"log_date" => "bad"}, ~D[2026-06-01]) == ~D[2026-06-01]
    end
  end
end
