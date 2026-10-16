defmodule BurpeeTrainer.ProgressGaugesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.ProgressGauges

  @today ~D[2026-10-13]
  @tz "Etc/UTC"

  defp goal(attrs) do
    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        burpee_type: :six_count,
        burpee_count_target: 150,
        duration_sec_target: 1200,
        date_target: ~D[2026-11-09],
        status: :active,
        updated_at: ~U[2026-10-01 10:00:00Z]
      },
      Map.new(attrs)
    )
  end

  defp session(reps, attrs \\ []) do
    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        burpee_type: :six_count,
        burpee_count_actual: reps,
        duration_sec_actual: 1200,
        completed_at: ~U[2026-10-10 10:00:00Z],
        tags: nil
      },
      Map.new(attrs)
    )
  end

  defp gauges(goals, sessions, today \\ @today),
    do: ProgressGauges.for_types(goals, sessions, today, @tz)

  test "nothing measured: both types are empty" do
    assert [%{kind: :none, burpee_type: :six_count}, %{kind: :none, burpee_type: :navy_seal}] =
             gauges([], [])
  end

  test "each type has its own goal, side by side" do
    six = goal([])
    navy = goal(burpee_type: :navy_seal, burpee_count_target: 60, date_target: ~D[2027-01-10])
    sessions = [session(130), session(20, burpee_type: :navy_seal)]

    assert [
             %{kind: :goal, goal: ^six, best: 130},
             %{kind: :goal, goal: ^navy, best: 20}
           ] = gauges([navy, six], sessions)
  end

  test "of two goals for one type, the nearest date leads" do
    near = goal(date_target: ~D[2026-11-09])
    far = goal(date_target: ~D[2027-02-01])
    assert [%{kind: :goal, goal: ^near}, _] = gauges([far, near], [session(130)])
  end

  test "one or two measured sessions: the first is the starting point" do
    first = session(110, completed_at: ~U[2026-10-08 10:00:00Z])

    assert [%{kind: :first, reps: 110}, %{kind: :none}] =
             gauges([], [session(115), first])
  end

  test "three measured sessions and no goal: the best, and the next goal" do
    sessions = for reps <- [20, 30, 25], do: session(reps, burpee_type: :navy_seal)

    assert [%{kind: :none}, %{kind: :best, best: 30, next: %{burpee_type: :navy_seal}}] =
             gauges([], sessions)
  end

  test "a rising goal carries its course; a goal without enough weeks does not" do
    rising =
      for {weeks_ago, reps} <- [{3, 100}, {2, 110}, {1, 120}, {0, 130}],
          do:
            session(reps,
              completed_at:
                DateTime.new!(Date.add(@today, -7 * weeks_ago), ~T[08:00:00], "Etc/UTC")
            )

    assert [%{kind: :goal, course: %{on_course?: true}}, _] = gauges([goal([])], rising)
    assert [%{kind: :goal, course: nil}, _] = gauges([goal([])], [session(130)])
  end

  test "a goal reached in the last week shows, with the next goal, until a new one is set" do
    reached = goal(status: :achieved, updated_at: ~U[2026-11-02 18:00:00Z])
    sessions = [session(152, completed_at: ~U[2026-11-02 17:00:00Z])]

    assert [
             %{
               kind: :reached,
               goal: ^reached,
               best: 152,
               reached_on: ~D[2026-11-02],
               next: %{burpee_count_target: 200}
             },
             _
           ] = gauges([reached], sessions, ~D[2026-11-05])

    next = goal(burpee_count_target: 200, date_target: ~D[2026-12-15])
    assert [%{kind: :goal, goal: ^next}, _] = gauges([reached, next], sessions, ~D[2026-11-05])
  end

  test "a goal reached more than a week ago no longer shows" do
    reached = goal(status: :achieved, updated_at: ~U[2026-10-01 18:00:00Z])
    sessions = [session(110), session(130), session(152)]
    assert [%{kind: :best}, _] = gauges([reached], sessions)
  end

  test "warmups and sessions longer than 20 minutes do not count toward best" do
    sessions = [
      session(120),
      session(100),
      session(200, tags: "warmup"),
      session(190, duration_sec_actual: 1500)
    ]

    assert [%{kind: :best, best: 120}, _] = gauges([], sessions)
  end

  property "one gauge per type, six-count first, each about its own type" do
    type = member_of([:six_count, :navy_seal])

    check all(
            sessions <-
              list_of(
                fixed_map(%{reps: integer(0..200), type: type, days_ago: integer(0..60)}),
                max_length: 12
              ),
            goals <-
              list_of(
                fixed_map(%{
                  type: type,
                  status: member_of([:active, :achieved, :proposed]),
                  target: integer(10..250)
                }),
                max_length: 4
              )
          ) do
      sessions =
        Enum.map(sessions, fn s ->
          session(s.reps,
            burpee_type: s.type,
            completed_at: DateTime.new!(Date.add(@today, -s.days_ago), ~T[08:00:00], "Etc/UTC")
          )
        end)

      goals =
        Enum.map(
          goals,
          &goal(burpee_type: &1.type, status: &1.status, burpee_count_target: &1.target)
        )

      result = gauges(goals, sessions)
      assert Enum.map(result, & &1.burpee_type) == [:six_count, :navy_seal]

      for gauge <- result,
          Map.has_key?(gauge, :goal),
          do: assert(gauge.goal.burpee_type == gauge.burpee_type)

      for gauge <- result,
          Map.has_key?(gauge, :next),
          do: assert(gauge.next.burpee_type == gauge.burpee_type)
    end
  end
end
