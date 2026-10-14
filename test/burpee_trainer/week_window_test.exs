defmodule BurpeeTrainer.WeekWindowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.WeekWindow

  defp session(type, sec, minutes_in, tags \\ nil),
    do: %{
      burpee_type: type,
      duration_sec_actual: sec,
      tags: tags,
      completed_at: DateTime.add(~U[2026-10-12 06:00:00Z], minutes_in * 60, :second)
    }

  test "an empty week is four 20-minute sessions, two of each type, alternating" do
    assert WeekWindow.lay_out([], 4_800) |> Enum.map(&{&1.status, &1.burpee_type}) == [
             left: :six_count,
             left: :navy_seal,
             left: :six_count,
             left: :navy_seal
           ]
  end

  test "done sessions come first in order; what is left goes to the type behind" do
    week = [session(:six_count, 1_200, 60), session(:six_count, 1_200, 0)]

    assert WeekWindow.lay_out(week, 4_800) |> Enum.map(&{&1.status, &1.burpee_type}) == [
             done: :six_count,
             done: :six_count,
             left: :navy_seal,
             left: :navy_seal
           ]
  end

  test "warmups do not count, and a met week has nothing left" do
    week = [session(:six_count, 4_800, 0), session(:navy_seal, 300, 5, "warmup")]
    assert [%{status: :done, burpee_type: :six_count}] = WeekWindow.lay_out(week, 4_800)
  end

  property "done time plus left time is at least the target, and left is never over it" do
    check all(
            sessions <-
              list_of(
                tuple({member_of([:six_count, :navy_seal]), integer(1..2_400)}),
                max_length: 6
              ),
            target <- member_of([1_200, 2_400, 3_600, 4_800])
          ) do
      week = sessions |> Enum.with_index() |> Enum.map(fn {{t, s}, i} -> session(t, s, i) end)
      items = WeekWindow.lay_out(week, target)
      {done, left} = Enum.split_with(items, &(&1.status == :done))
      done_sec = Enum.sum_by(done, & &1.duration_sec)
      left_sec = Enum.sum_by(left, & &1.duration_sec)

      assert left_sec == max(target - done_sec, 0)
      assert Enum.all?(left, &(&1.duration_sec in 1..1_200))
      assert length(done) == length(week)
    end
  end
end
