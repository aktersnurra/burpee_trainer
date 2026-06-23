defmodule BurpeeTrainer.PlanSolver.BoundaryPlacement do
  @moduledoc """
  Places automatic resets and explicit rests on real elapsed-time set boundaries.
  """

  alias BurpeeTrainer.PlanSolver.ExplicitRest

  @type reset :: %{
          kind: :mid | :late,
          after_set: pos_integer,
          starts_at_sec: float,
          duration_sec: pos_integer
        }
  @type explicit :: %{
          after_set: pos_integer,
          starts_at_sec: float,
          duration_sec: pos_integer,
          source: ExplicitRest.t()
        }
  @type placement :: %{auto_resets: [reset], explicit_rests: [explicit]}

  @spec enumerate([pos_integer], float, pos_integer, [pos_integer], [ExplicitRest.t()]) :: [
          placement
        ]
  def enumerate(
        set_pattern,
        sec_per_rep,
        normal_recovery_sec,
        reset_durations_sec,
        explicit_rests
      )
      when is_list(set_pattern) do
    set_pattern = Enum.map(set_pattern, &round/1)

    set_pattern
    |> reset_templates(sec_per_rep, normal_recovery_sec, reset_durations_sec)
    |> Enum.flat_map(fn resets ->
      place_explicit_rests(set_pattern, sec_per_rep, normal_recovery_sec, resets, explicit_rests)
    end)
    |> Enum.uniq_by(&placement_key/1)
    |> Enum.sort_by(&placement_key/1)
  end

  defp reset_templates(set_pattern, sec_per_rep, normal_recovery_sec, reset_durations_sec) do
    target_sec =
      implied_target_sec(set_pattern, sec_per_rep, normal_recovery_sec, reset_durations_sec)

    windows = reset_windows(target_sec)

    [[]] ++
      single_reset_templates(
        set_pattern,
        sec_per_rep,
        normal_recovery_sec,
        windows,
        reset_durations_sec
      ) ++
      double_reset_templates(
        set_pattern,
        sec_per_rep,
        normal_recovery_sec,
        windows,
        reset_durations_sec
      )
  end

  defp single_reset_templates(
         set_pattern,
         sec_per_rep,
         normal_recovery_sec,
         windows,
         reset_durations_sec
       ) do
    for window <- windows,
        duration <- reset_duration_options(reset_durations_sec),
        reset <-
          legal_resets(
            set_pattern,
            sec_per_rep,
            normal_recovery_sec,
            [%{kind: window.kind, duration_sec: duration}],
            window
          ) do
      [reset]
    end
  end

  defp double_reset_templates(
         set_pattern,
         sec_per_rep,
         normal_recovery_sec,
         windows,
         reset_durations_sec
       ) do
    mid_window = Enum.find(windows, &(&1.kind == :mid))
    late_window = Enum.find(windows, &(&1.kind == :late))

    if mid_window && late_window do
      durations = reset_duration_pairs(reset_durations_sec)

      for {mid_duration, late_duration} <- durations,
          mid <-
            legal_resets(
              set_pattern,
              sec_per_rep,
              normal_recovery_sec,
              [%{kind: :mid, duration_sec: mid_duration}],
              mid_window
            ),
          late <-
            legal_resets(
              set_pattern,
              sec_per_rep,
              normal_recovery_sec,
              [mid, %{kind: :late, duration_sec: late_duration}],
              late_window
            ),
          mid.after_set < late.after_set do
        [mid, late]
      end
    else
      []
    end
  end

  defp legal_resets(set_pattern, sec_per_rep, normal_recovery_sec, resets, window) do
    reset_specs = Enum.filter(resets, &Map.has_key?(&1, :after_set))
    pending = Enum.find(resets, &(not Map.has_key?(&1, :after_set)))

    boundaries = boundary_times(set_pattern, sec_per_rep, normal_recovery_sec, reset_specs)

    boundaries
    |> Enum.filter(fn boundary -> boundary.after_set < length(set_pattern) end)
    |> Enum.filter(fn boundary ->
      boundary.starts_at_sec >= window.left and boundary.starts_at_sec <= window.right
    end)
    |> Enum.map(fn boundary ->
      %{
        kind: pending.kind,
        after_set: boundary.after_set,
        starts_at_sec: boundary.starts_at_sec,
        duration_sec: pending.duration_sec
      }
    end)
  end

  defp place_explicit_rests(_set_pattern, _sec_per_rep, _normal_recovery_sec, resets, []),
    do: [%{auto_resets: Enum.sort_by(resets, & &1.after_set), explicit_rests: []}]

  defp place_explicit_rests(set_pattern, sec_per_rep, normal_recovery_sec, resets, explicit_rests) do
    reset_indexes = resets |> Enum.map(& &1.after_set) |> MapSet.new()
    boundaries = boundary_times(set_pattern, sec_per_rep, normal_recovery_sec, resets)

    explicit_options =
      Enum.map(explicit_rests, fn explicit_rest ->
        boundaries
        |> Enum.reject(&MapSet.member?(reset_indexes, &1.after_set))
        |> Enum.filter(fn boundary ->
          abs(boundary.starts_at_sec - explicit_rest.target_elapsed_sec) <=
            explicit_rest.tolerance_sec
        end)
        |> Enum.sort_by(fn boundary ->
          {abs(boundary.starts_at_sec - explicit_rest.target_elapsed_sec), boundary.after_set}
        end)
        |> Enum.map(fn boundary ->
          %{
            after_set: boundary.after_set,
            starts_at_sec: boundary.starts_at_sec,
            duration_sec: explicit_rest.duration_sec,
            source: explicit_rest
          }
        end)
      end)

    if Enum.any?(explicit_options, &(&1 == [])) do
      []
    else
      explicit_options
      |> cartesian_product()
      |> Enum.map(fn placed_explicit ->
        %{auto_resets: Enum.sort_by(resets, & &1.after_set), explicit_rests: placed_explicit}
      end)
    end
  end

  defp boundary_times(set_pattern, sec_per_rep, normal_recovery_sec, resets) do
    reset_by_set = Map.new(resets, &{&1.after_set, &1.duration_sec})

    {_elapsed, boundaries} =
      set_pattern
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, []}, fn {reps, set_index}, {elapsed, boundaries} ->
        elapsed = elapsed + reps * sec_per_rep
        boundaries = [%{after_set: set_index, starts_at_sec: elapsed} | boundaries]

        recovery_sec =
          cond do
            set_index == length(set_pattern) -> 0
            Map.has_key?(reset_by_set, set_index) -> Map.fetch!(reset_by_set, set_index)
            true -> normal_recovery_sec
          end

        {elapsed + recovery_sec, boundaries}
      end)

    Enum.reverse(boundaries)
  end

  defp implied_target_sec(set_pattern, sec_per_rep, normal_recovery_sec, reset_durations_sec) do
    work_sec = Enum.sum(set_pattern) * sec_per_rep
    gap_count = max(length(set_pattern) - 1, 0)

    reset_count =
      min(
        length(reset_durations_sec),
        reset_count_for_duration_guess(work_sec, gap_count, normal_recovery_sec)
      )

    reset_total = reset_durations_sec |> Enum.take(reset_count) |> Enum.sum()
    normal_count = max(gap_count - reset_count, 0)

    work_sec + normal_count * normal_recovery_sec + reset_total
  end

  defp reset_count_for_duration_guess(work_sec, gap_count, normal_recovery_sec) do
    duration_with_normal = work_sec + gap_count * normal_recovery_sec

    cond do
      duration_with_normal >= 18 * 60 -> 2
      duration_with_normal >= 12 * 60 -> 1
      true -> 0
    end
  end

  defp reset_windows(target_sec) do
    cond do
      target_sec < 12 * 60 ->
        []

      target_sec < 18 * 60 ->
        [
          %{
            kind: :mid,
            center: 0.60 * target_sec,
            left: 0.55 * target_sec,
            right: 0.67 * target_sec
          }
        ]

      true ->
        [
          %{
            kind: :mid,
            center: 0.60 * target_sec,
            left: 0.55 * target_sec,
            right: 0.67 * target_sec
          },
          %{
            kind: :late,
            center: 0.90 * target_sec,
            left: 0.85 * target_sec,
            right: 0.96 * target_sec
          }
        ]
    end
  end

  defp reset_duration_options([]), do: [90]
  defp reset_duration_options(reset_durations_sec), do: Enum.uniq(reset_durations_sec)

  defp reset_duration_pairs([]), do: [{90, 90}]
  defp reset_duration_pairs([one]), do: [{one, one}]
  defp reset_duration_pairs([first, second | _]), do: [{first, second}]

  defp cartesian_product([]), do: [[]]

  defp cartesian_product([head | tail]) do
    for item <- head, rest <- cartesian_product(tail), do: [item | rest]
  end

  defp placement_key(placement) do
    {
      Enum.map(placement.auto_resets, &{&1.kind, &1.after_set, &1.duration_sec}),
      Enum.map(placement.explicit_rests, &{&1.after_set, &1.duration_sec})
    }
  end
end
