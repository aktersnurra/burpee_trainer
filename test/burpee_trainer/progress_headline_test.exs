defmodule BurpeeTrainer.ProgressHeadlineTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.ProgressHeadline

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

  test "nothing measured: no headline" do
    assert %{headline: %{kind: :none}, others: []} = ProgressHeadline.pick([], [], @today, @tz)
  end

  test "one or two measured sessions: the first is your starting point" do
    first = session(110, completed_at: ~U[2026-10-08 10:00:00Z])
    later = session(115)

    assert %{headline: %{kind: :first, burpee_type: :six_count, reps: 110}} =
             ProgressHeadline.pick([], [later, first], @today, @tz)
  end

  test "three measured sessions and no goal: your best, and the next goal" do
    sessions = [session(110), session(130), session(120)]

    assert %{headline: %{kind: :best, best: 130, next: %{burpee_count_target: 150}}} =
             ProgressHeadline.pick([], sessions, @today, @tz)
  end

  test "an active goal leads with best over target; the nearest date wins, others follow" do
    near = goal(date_target: ~D[2026-11-09])

    far =
      goal(burpee_type: :navy_seal, burpee_count_target: 60, date_target: ~D[2027-01-10])

    sessions = [session(130), session(20, burpee_type: :navy_seal)]

    assert %{headline: %{kind: :goal, goal: ^near, best: 130}, others: [%{goal: ^far, best: 20}]} =
             ProgressHeadline.pick([far, near], sessions, @today, @tz)
  end

  test "a goal reached in the last week leads, with how early, and the next goal" do
    reached = goal(status: :achieved, updated_at: ~U[2026-11-02 18:00:00Z])
    sessions = [session(152, completed_at: ~U[2026-11-02 17:00:00Z])]

    assert %{
             headline: %{
               kind: :reached,
               goal: ^reached,
               best: 152,
               reached_on: ~D[2026-11-02],
               next: %{burpee_count_target: 200}
             }
           } = ProgressHeadline.pick([reached], sessions, ~D[2026-11-05], @tz)
  end

  test "a goal reached more than a week ago no longer leads" do
    reached = goal(status: :achieved, updated_at: ~U[2026-10-01 18:00:00Z])
    sessions = [session(110), session(130), session(152)]

    assert %{headline: %{kind: :best}} =
             ProgressHeadline.pick([reached], sessions, @today, @tz)
  end

  test "warmups and sessions longer than 20 minutes do not count toward best" do
    sessions = [
      session(120),
      session(100),
      session(200, tags: "warmup"),
      session(190, duration_sec_actual: 1500)
    ]

    assert %{headline: %{kind: :best, best: 120}} =
             ProgressHeadline.pick([], sessions, @today, @tz)
  end

  test "someone who only does Navy SEAL sees Navy SEAL" do
    sessions = for reps <- [20, 25, 30], do: session(reps, burpee_type: :navy_seal)

    assert %{headline: %{kind: :best, burpee_type: :navy_seal, best: 30}} =
             ProgressHeadline.pick([], sessions, @today, @tz)
  end
end
