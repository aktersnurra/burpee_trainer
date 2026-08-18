defmodule BurpeeTrainer.WeeklyTrainingContractTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.WeeklyTrainingContract
  alias BurpeeTrainer.WeeklyTrainingContract.PriorWeekResult

  test "classifies a UTC timestamp by its Stockholm local date" do
    session = session(~U[2026-03-29 22:30:00Z])

    assert %{completed_sec: 1_200, completed_min: 20} =
             WeeklyTrainingContract.status(
               [session],
               ~D[2026-03-30],
               "Europe/Stockholm"
             )
  end

  test "excludes a UTC Monday timestamp that is still in the prior Los Angeles local week" do
    session = session(~U[2026-08-03 00:30:00Z])

    assert %{completed_sec: 0, completed_min: 0} =
             WeeklyTrainingContract.status(
               [session],
               ~D[2026-08-03],
               "America/Los_Angeles"
             )
  end

  test "retains exact second boundaries while keeping compatible minute display fields" do
    sessions = [
      session(~U[2026-08-03 12:00:00Z], duration_sec_actual: 2_400, burpee_type: :six_count),
      session(~U[2026-08-04 12:00:00Z], duration_sec_actual: 2_399, burpee_type: :navy_seal)
    ]

    assert %{target_sec: 4_800, completed_sec: 4_799, remaining_sec: 1} =
             status = WeeklyTrainingContract.status(sessions, ~D[2026-08-03], "Etc/UTC")

    assert status.completed_min == 79
    assert status.remaining_min == 1
  end

  test "derives a complete prior-week result without carrying debt into the new week" do
    prior_week_start = ~D[2026-08-03]

    sessions = [
      session(~U[2026-08-03 09:00:00Z], id: 1, duration_sec_actual: 1_200),
      session(~U[2026-08-04 09:00:00Z], id: 2, duration_sec_actual: 1_200),
      session(~U[2026-08-05 09:00:00Z], id: 3, duration_sec_actual: 1_200),
      session(~U[2026-08-06 09:00:00Z], id: 4, duration_sec_actual: 1_200)
    ]

    expected = %PriorWeekResult{
      week_start: prior_week_start,
      completed_sec: 4_800,
      complete?: true,
      workout_count: 4,
      evidence_refs: [
        %{kind: :session, id: 4},
        %{kind: :session, id: 3},
        %{kind: :session, id: 2},
        %{kind: :session, id: 1}
      ]
    }

    assert WeeklyTrainingContract.prior_week_result(sessions, prior_week_start, "Etc/UTC") ==
             expected

    assert WeeklyTrainingContract.prior_week_result(sessions, prior_week_start, "Etc/UTC") ==
             expected

    assert %{completed_sec: 0, remaining_sec: 4_800} =
             WeeklyTrainingContract.status(sessions, ~D[2026-08-10], "Etc/UTC")
  end

  test "derives an incomplete prior-week result with bounded evidence refs" do
    prior_week_start = ~D[2026-08-03]

    sessions =
      for id <- 1..13 do
        session(
          DateTime.add(~U[2026-08-03 08:00:00Z], id * 3_600, :second),
          id: id,
          duration_sec_actual: 100,
          burpee_type: if(rem(id, 2) == 0, do: :navy_seal, else: :six_count)
        )
      end

    assert %PriorWeekResult{
             week_start: ^prior_week_start,
             completed_sec: 1_300,
             complete?: false,
             workout_count: 13,
             evidence_refs: evidence_refs
           } = WeeklyTrainingContract.prior_week_result(sessions, prior_week_start, "Etc/UTC")

    assert length(evidence_refs) == 12
    assert Enum.take(Enum.map(evidence_refs, & &1.id), 3) == [13, 12, 11]
    assert Enum.at(evidence_refs, -1).id == 2
  end

  test "orders tied prior-week evidence refs by descending id regardless of input order" do
    prior_week_start = ~D[2026-08-03]
    tied_at = ~U[2026-08-05 09:00:00Z]

    sessions = [
      session(tied_at, id: 3, duration_sec_actual: 100),
      session(tied_at, id: 9, duration_sec_actual: 100),
      session(tied_at, id: 1, duration_sec_actual: 100),
      session(tied_at, id: 7, duration_sec_actual: 100)
    ]

    assert %PriorWeekResult{evidence_refs: evidence_refs} =
             WeeklyTrainingContract.prior_week_result(sessions, prior_week_start, "Etc/UTC")

    assert Enum.map(evidence_refs, & &1.id) == [9, 7, 3, 1]
  end

  defp session(completed_at, attrs \\ []) do
    %{
      id: Keyword.get(attrs, :id, 1),
      completed_at: completed_at,
      duration_sec_actual: Keyword.get(attrs, :duration_sec_actual, 1_200),
      burpee_type: Keyword.get(attrs, :burpee_type, :six_count),
      tags: Keyword.get(attrs, :tags)
    }
  end
end
