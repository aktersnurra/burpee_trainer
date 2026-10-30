defmodule BurpeeTrainer.Coach.ProposalEditTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.{ProposalEdit, WorkoutRequest}

  defp request(attrs \\ %{}) do
    {:ok, request} =
      %{
        "burpee_type" => "six_count",
        "target_reps" => 150,
        "target_duration_sec" => 1_200,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      }
      |> Map.merge(attrs)
      |> WorkoutRequest.new()

    request
  end

  defp definition do
    %{
      "version" => 1,
      "name" => "Steady 150",
      "rationale" => "Two even sets.",
      "burpee_type" => "six_count",
      "pacing_style" => "unbroken",
      "target_reps" => 150,
      "target_duration_sec" => 1_200,
      "events" => [
        %{"kind" => "work", "reps" => 75, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 450},
        %{"kind" => "work", "reps" => 75, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ]
    }
  end

  defp total(attrs) do
    attrs["events"]
    |> Enum.map(fn
      %{"kind" => "work"} = w -> (w["reps"] - 1) * w["sec_per_rep"] + w["sec_per_burpee"]
      %{"kind" => "rest", "duration_sec" => d} -> d
    end)
    |> Enum.sum()
    |> Kernel.+(0)
  end

  test "fewer reps in a set: the rest takes the time, the length and the name follow" do
    assert {:ok, attrs, request} = ProposalEdit.apply(definition(), request(), [0], :reps, -1)

    assert [%{"reps" => 74}, %{"kind" => "rest", "duration_sec" => rest}, %{"reps" => 75}] =
             attrs["events"]

    assert rest == 455
    assert attrs["target_reps"] == 149 and request.target_reps == 149
    assert attrs["target_duration_sec"] == 1_200
    assert attrs["name"] == "Steady 149"
    assert total(attrs) == 1_200
  end

  test "a slower beat in an unbroken set moves its movement with it" do
    assert {:ok, attrs, _} = ProposalEdit.apply(definition(), request(), [0, 2], :every, 1)
    assert [%{"sec_per_rep" => 5.5, "sec_per_burpee" => 5.5} | _] = attrs["events"]
    assert attrs["target_duration_sec"] == 1_200
  end

  test "what cannot fit is refused" do
    # 150 reps at 8.5s each is more than 20 minutes.
    steps =
      Enum.reduce_while(1..20, definition(), fn _, d ->
        case ProposalEdit.apply(d, request(), [0, 2], :every, 1) do
          {:ok, attrs, _} -> {:cont, attrs}
          :error -> {:halt, :refused}
        end
      end)

    assert steps == :refused
    assert :error == ProposalEdit.apply(definition(), request(), [1], :reps, 1)

    {:ok, timed} =
      request(%{"timed_rests" => [%{"start_sec" => 600, "duration_sec" => 60}]})
      |> then(&{:ok, &1})

    assert :error == ProposalEdit.apply(definition(), timed, [0], :reps, 1)
  end

  test "a named set list and a named pace follow the edit" do
    request = request(%{"set_reps" => [75, 75], "requested_pace_sec" => 5})
    assert {:ok, _attrs, request} = ProposalEdit.apply(definition(), request, [2], :reps, 1)
    assert request.set_reps == [75, 76]

    assert {:ok, _attrs, request} =
             ProposalEdit.apply(
               definition(),
               request(%{"requested_pace_sec" => 5}),
               [0, 2],
               :every,
               -1
             )

    assert request.requested_pace_sec == 4.5
  end
end
