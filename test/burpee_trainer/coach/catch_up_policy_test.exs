defmodule BurpeeTrainer.Coach.CatchUpPolicyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.CatchUpPolicy

  describe "rolling_pb/3" do
    test "keeps same-type authoritative exact twenty-minute sessions within the trailing six weeks" do
      now = ~U[2025-01-15 12:00:00Z]
      six_weeks_ago = DateTime.add(now, -42 * 24 * 60 * 60, :second)

      sessions = [
        session(%{
          id: 1,
          burpee_type: :six_count,
          burpee_count_actual: 98,
          duration_sec_planned: 1_200,
          plan_id: 1,
          completed_at: DateTime.add(now, -3 * 24 * 60 * 60, :second)
        }),
        session(%{
          id: 2,
          burpee_type: :six_count,
          burpee_count_actual: 99,
          duration_sec_planned: 1_200,
          plan_id: 2,
          completed_at: six_weeks_ago
        }),
        session(%{
          id: 3,
          burpee_type: :six_count,
          burpee_count_actual: 120,
          duration_sec_planned: 1_200,
          source_kind: :manual,
          completed_at: DateTime.add(now, -2 * 24 * 60 * 60, :second)
        }),
        session(%{
          id: 4,
          burpee_type: :six_count,
          burpee_count_actual: 130,
          duration_sec_planned: 1_199,
          plan_id: 4,
          completed_at: DateTime.add(now, -24 * 60 * 60, :second)
        }),
        session(%{
          id: 5,
          burpee_type: :navy_seal,
          burpee_count_actual: 140,
          duration_sec_planned: 1_200,
          plan_id: 5,
          completed_at: DateTime.add(now, -24 * 60 * 60, :second)
        }),
        session(%{
          id: 6,
          burpee_type: :six_count,
          burpee_count_actual: 150,
          duration_sec_planned: 1_200,
          plan_id: 6,
          completed_at: DateTime.add(six_weeks_ago, -1, :second)
        }),
        session(%{
          id: 7,
          burpee_type: :six_count,
          burpee_count_actual: 160,
          duration_sec_planned: 1_200,
          plan_id: 7,
          tags: "warmup",
          completed_at: DateTime.add(now, -24 * 60 * 60, :second)
        }),
        session(%{
          id: 8,
          burpee_type: :six_count,
          burpee_count_actual: 170,
          duration_sec_planned: 1_200,
          plan_id: 8,
          source_kind: :mystery,
          completed_at: DateTime.add(now, -12 * 60 * 60, :second)
        })
      ]

      assert {:ok, pb} = CatchUpPolicy.rolling_pb(sessions, :six_count, now)
      assert pb.session_id == 2
      assert pb.reps == 99
      assert pb.burpee_type == :six_count
      assert pb.duration_sec_planned == 1_200
    end

    test "returns none when no authoritative exact twenty-minute pb exists" do
      now = ~U[2025-01-15 12:00:00Z]

      sessions = [
        session(%{
          id: 1,
          burpee_type: :six_count,
          burpee_count_actual: 80,
          duration_sec_planned: 900,
          plan_id: 1
        }),
        session(%{
          id: 2,
          burpee_type: :six_count,
          burpee_count_actual: 90,
          duration_sec_planned: 1_200,
          source_kind: :manual
        }),
        session(%{
          id: 3,
          burpee_type: :navy_seal,
          burpee_count_actual: 40,
          duration_sec_planned: 1_200,
          plan_id: 3
        })
      ]

      assert :none = CatchUpPolicy.rolling_pb(sessions, :six_count, now)
    end
  end

  describe "prescription/3" do
    test "uses the exact integer catch-up formulas across factor boundaries" do
      assert {:ok, %{duration_min: 40, factor_num: 75, ceiling_reps: 150}} =
               CatchUpPolicy.prescription(2_400, 100, %{})

      assert {:ok, %{duration_min: 41, factor_num: 60, ceiling_reps: 123}} =
               CatchUpPolicy.prescription(2_401, 100, %{})

      assert {:ok, %{duration_min: 60, factor_num: 60, ceiling_reps: 180}} =
               CatchUpPolicy.prescription(3_600, 100, %{})

      assert {:ok, %{duration_min: 61, factor_num: 50, ceiling_reps: 152}} =
               CatchUpPolicy.prescription(3_601, 100, %{})

      assert {:ok, %{duration_min: 80, factor_num: 50, ceiling_reps: 200}} =
               CatchUpPolicy.prescription(4_800, 100, %{})
    end

    test "rejects remaining seconds below the catch-up floor" do
      assert {:error, :not_eligible} = CatchUpPolicy.prescription(2_399, 100, %{})
    end
  end

  defp session(attrs) do
    Map.merge(
      %{
        burpee_type: :six_count,
        burpee_count_actual: 0,
        duration_sec_actual: 1_200,
        duration_sec_planned: 1_200,
        state: :completed,
        source_kind: :plan,
        display_name_snapshot: "Prescribed session",
        program_snapshot: %{},
        tags: nil,
        completed_at: ~U[2025-01-01 12:00:00Z]
      },
      attrs
    )
  end
end
