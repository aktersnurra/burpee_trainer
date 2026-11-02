defmodule BurpeeTrainer.Coach.CatchUpPolicyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.CatchUpPolicy

  describe "rolling_pb/3" do
    test "keeps same-type prescribed plan twenty-minute sessions within the trailing six weeks, else none" do
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
        }),
        session(%{
          id: 9,
          burpee_count_actual: 180,
          source_kind: :video,
          video_snapshot: %{"name" => "Follow along"},
          completed_at: DateTime.add(now, -12 * 60 * 60, :second)
        })
      ]

      assert {:ok, pb} = CatchUpPolicy.rolling_pb(sessions, :six_count, now)
      assert pb.session_id == 2
      assert pb.reps == 99
      assert pb.burpee_type == :six_count
      assert pb.duration_sec_planned == 1_200

      assert :none =
               sessions
               |> Enum.reject(&(&1.id in [1, 2]))
               |> CatchUpPolicy.rolling_pb(:six_count, now)
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
