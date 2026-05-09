defmodule BurpeeTrainer.PlanWizard.ReservationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{PlanInput, Reservation, SlotModel}

  defp input(overrides) do
    base = %PlanInput{
      name: "Test plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      sec_per_burpee: 5.0,
      pacing_style: :even,
      reps_per_set: nil
    }

    struct!(base, overrides)
  end

  defp model(overrides, reps_per_set \\ nil) do
    SlotModel.new(input(overrides), reps_per_set)
  end

  describe "place/1 — no reservations" do
    test ":even returns empty reservations list" do
      m = model(%{})
      assert {:ok, %SlotModel{reservations: []}} = Reservation.place(m)
    end

    test ":unbroken returns empty reservations list" do
      m = model(%{pacing_style: :unbroken, burpee_count_target: 50}, 10)
      assert {:ok, %SlotModel{reservations: []}} = Reservation.place(m)
    end
  end

  describe "place/1 — :even single reservation" do
    test "places at slot whose cumulative time matches target_min" do
      # 100 reps, 20-min target, sec_per_burpee=5, total_rest=60
      # shaved cadence = (1200 - 60) / 100 = 11.4s/rep
      # rest at min 5 → target 300s, ideal slot = round(300/11.4) = 26
      m =
        model(%{
          additional_rests: [%{rest_sec: 60, target_min: 5}]
        })

      assert {:ok, %SlotModel{reservations: [r]}} = Reservation.place(m)
      assert r.slot == 26
      assert r.rest_sec == 60
      assert r.target_min == 5
    end
  end

  describe "place/1 — :even multiple reservations" do
    test "sorts by target_min and bumps later slots when needed" do
      # 100 reps → 99 slots. Budget = 1200 − 500 − 120 = 580. Per-slot rest = 580/99 ≈ 5.859.
      # Projected slot time = i × (5 + 5.859) = 10.859i.
      # min 5  → round(300 / 10.859) = 28
      # min 10 → round(600 / 10.859) = 55
      # NB: legacy divided by `total_reps` (100) instead of slot count (99); purist
      # uses slot count, so slot indices may differ from legacy by ±1.
      m =
        model(%{
          additional_rests: [
            %{rest_sec: 60, target_min: 10},
            %{rest_sec: 60, target_min: 5}
          ]
        })

      assert {:ok, %SlotModel{reservations: [r1, r2]}} = Reservation.place(m)
      assert r1.target_min == 5
      assert r1.slot == 28
      assert r2.target_min == 10
      assert r2.slot == 55
    end
  end

  describe "place/1 — :even out of tolerance" do
    test "errors when nearest slot is more than 30s from target" do
      # 4 reps, 20-min target, sec_per_burpee = 5 → shaved cadence = (1200 - 60) / 4 = 285s/rep
      # slot 1 is at 285s; target is 60s → off by 225s, way past 30s tolerance.
      m =
        model(%{
          burpee_count_target: 4,
          additional_rests: [%{rest_sec: 60, target_min: 1}]
        })

      assert {:error, [msg]} = Reservation.place(m)
      assert msg =~ "cannot place rest at min 1"
      assert msg =~ "nearest rep boundary"
      assert msg =~ "max 30s"
    end
  end

  describe "place/1 — :unbroken single reservation" do
    test "places at the set boundary nearest to target" do
      # 50 reps @ 5s/rep = 250s work; 20 min target = 1200s; 950s between-rest.
      # 5 sets of 10 reps → 4 boundaries.
      # boundary slots: 10, 20, 30, 40
      # each slot accumulates: i × 5 + (i / 10) × (950/4) at boundary slots
      # rest at min 5 → 300s. Closest boundary by projected time → check by computing.
      m =
        model(
          %{
            pacing_style: :unbroken,
            burpee_count_target: 50,
            additional_rests: [%{rest_sec: 30, target_min: 5}]
          },
          10
        )

      assert {:ok, %SlotModel{reservations: [r]}} = Reservation.place(m)
      assert r.slot in [10, 20, 30, 40]
      assert r.rest_sec == 30
    end
  end

  describe "place/1 — :unbroken with only one set" do
    test "errors when reps_per_set ≥ total_reps (no boundaries)" do
      # 10 reps, reps_per_set = 10 → 1 set, 0 boundary slots
      m =
        model(
          %{
            pacing_style: :unbroken,
            burpee_count_target: 10,
            target_duration_min: 5,
            additional_rests: [%{rest_sec: 30, target_min: 2}]
          },
          10
        )

      assert {:error, [msg]} = Reservation.place(m)
      assert msg =~ "cannot place rest at min 2"
      assert msg =~ "only one set"
    end
  end

  describe "place/1 — :unbroken out of tolerance" do
    test "errors when nearest boundary is more than 30s from target" do
      # 20 reps, 5 per set → boundary slots 5, 10, 15
      # 20-min target, 5s/rep work = 100s; between-rest = 1100s split across 3 gaps
      # boundary times: ~5×5 + 1×(1100/3) ≈ 392s for slot 5
      # Request rest at min 1 (60s) → far from 392s.
      m =
        model(
          %{
            pacing_style: :unbroken,
            burpee_count_target: 20,
            additional_rests: [%{rest_sec: 30, target_min: 1}]
          },
          5
        )

      assert {:error, [msg]} = Reservation.place(m)
      assert msg =~ "cannot place rest at min 1"
      assert msg =~ "nearest set boundary"
      assert msg =~ "max 30s"
    end
  end

  describe "place/1 — reservation count parity with legacy" do
    test ":even returns one reservation per input rest" do
      m =
        model(%{
          additional_rests: [
            %{rest_sec: 30, target_min: 5},
            %{rest_sec: 45, target_min: 10},
            %{rest_sec: 60, target_min: 15}
          ]
        })

      assert {:ok, %SlotModel{reservations: rs}} = Reservation.place(m)
      assert length(rs) == 3
      assert Enum.map(rs, & &1.target_min) == [5, 10, 15]
    end
  end
end
