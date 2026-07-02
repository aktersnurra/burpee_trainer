defmodule BurpeeTrainer.Fixtures do
  @moduledoc """
  Builders for test data. Each builder accepts an attribute override map
  so tests can override just the fields they care about. All builders
  persist via the corresponding context so constraints and changesets
  are exercised.
  """

  alias BurpeeTrainer.{Accounts, Goals, Workouts}

  @doc """
  Build and register a user. Username defaults are uniquified via
  `System.unique_integer/1` so fixtures can be called many times per
  test.
  """
  def user_fixture(attrs \\ %{}) do
    suffix =
      [System.system_time(:nanosecond), System.unique_integer([:positive, :monotonic])]
      |> Enum.map(&Integer.to_string(&1, 36))
      |> Enum.join("_")

    {:ok, user} =
      attrs
      |> Enum.into(%{
        "username" => "user_#{suffix}",
        "password" => "correct-horse-battery-staple"
      })
      |> Accounts.register_user()

    user
  end

  @doc """
  Build a source-backed plan. Legacy block overrides are still accepted so older
  editor tests can describe a persisted editor shape, but executable truth comes
  from explicit `source_json` or the fixture's source defaults.
  """
  def plan_fixture(user, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    defaults = %{
      "name" => "Test plan",
      "burpee_type" => "six_count",
      "blocks" => default_plan_blocks(),
      "source_json" => default_source_json(attrs)
    }

    {:ok, plan} = Workouts.create_plan(user, Map.merge(defaults, attrs))
    plan
  end

  @doc """
  Build a completed session tied to a plan.
  """
  def session_from_plan_fixture(user, plan, attrs \\ %{}) do
    defaults = %{
      "burpee_type" => to_string(plan.burpee_type),
      "burpee_count_planned" => 30,
      "duration_sec_planned" => 120,
      "burpee_count_actual" => 30,
      "duration_sec_actual" => 118
    }

    {:ok, session} =
      Workouts.create_session_from_plan(user, plan, Map.merge(defaults, stringify_keys(attrs)))

    session
  end

  @doc """
  Build a free-form session.
  """
  def free_form_session_fixture(user, attrs \\ %{}) do
    defaults = %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 25,
      "duration_sec_actual" => 100
    }

    {:ok, session} =
      Workouts.create_free_form_session(user, Map.merge(defaults, stringify_keys(attrs)))

    session
  end

  @doc """
  Build an active goal. Defaults to a target 4 weeks out from today
  with a 50 → 70 rep progression.
  """
  def goal_fixture(user, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 70,
      "duration_sec_target" => 300,
      "date_target" => Date.to_iso8601(Date.add(today, 28)),
      "burpee_count_baseline" => 50,
      "duration_sec_baseline" => 240,
      "date_baseline" => Date.to_iso8601(today)
    }

    {:ok, goal} = Goals.create_goal(user, Map.merge(defaults, stringify_keys(attrs)))
    goal
  end

  @doc """
  Build a video. No user scoping — videos are global.
  """
  def video_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      name: "Test Video #{n}",
      filename: "video_#{n}.mp4",
      burpee_type: :six_count,
      duration_sec: 1200,
      burpee_count: nil
    }

    {:ok, video} = BurpeeTrainer.Videos.create_video(Map.merge(defaults, attrs))
    video
  end

  defp default_plan_blocks do
    [
      %{
        "position" => 1,
        "repeat_count" => 1,
        "sets" => [
          %{
            "position" => 1,
            "burpee_count" => 10,
            "sec_per_rep" => 6.0,
            "sec_per_burpee" => 3.0,
            "end_of_set_rest" => 30
          },
          %{
            "position" => 2,
            "burpee_count" => 10,
            "sec_per_rep" => 6.0,
            "sec_per_burpee" => 3.0,
            "end_of_set_rest" => 30
          },
          %{
            "position" => 3,
            "burpee_count" => 10,
            "sec_per_rep" => 6.0,
            "sec_per_burpee" => 3.0,
            "end_of_set_rest" => 0
          }
        ]
      }
    ]
  end

  defp default_source_json(%{"source_json" => source}) when is_map(source), do: source

  defp default_source_json(attrs) do
    blocks = Map.get(attrs, "blocks", default_plan_blocks())
    burpee_type = Map.get(attrs, "burpee_type", "six_count")
    pacing_style = Map.get(attrs, "pacing_style", "even")
    block_pattern = source_pattern(attrs, blocks, burpee_type, pacing_style)
    target_reps = Map.get(attrs, "burpee_count_target") || Enum.sum(block_pattern) || 30

    source = %{
      "burpee_type" => burpee_type,
      "target_reps" => target_reps,
      "target_duration_sec" => fixture_target_duration_sec(attrs),
      "pacing_style" => pacing_style,
      "block_pattern" => block_pattern,
      "explicit_rests" => Map.get(attrs, "explicit_rests", [])
    }

    maybe_put_unbroken_max(source, attrs, block_pattern)
  end

  defp fixture_target_duration_sec(%{"target_duration_sec" => seconds}) when is_integer(seconds),
    do: seconds

  defp fixture_target_duration_sec(%{"target_duration_min" => minutes}) when is_integer(minutes),
    do: minutes * 60

  defp fixture_target_duration_sec(_attrs), do: 1_200

  defp source_pattern(attrs, _blocks, _burpee_type, _pacing_style)
       when is_map_key(attrs, "block_pattern") do
    Map.fetch!(attrs, "block_pattern")
  end

  defp source_pattern(attrs, blocks, burpee_type, "unbroken") do
    max_reps = source_max_unbroken_reps(attrs, blocks, burpee_type)
    [min(max_reps, default_unbroken_source_set_size(burpee_type))]
  end

  defp source_pattern(_attrs, blocks, _burpee_type, _pacing_style),
    do: source_block_pattern(blocks)

  defp source_block_pattern(blocks) when is_list(blocks) do
    blocks
    |> Enum.sort_by(&(Map.get(&1, "position") || 0))
    |> Enum.flat_map(fn block ->
      motif =
        block
        |> Map.get("sets", [])
        |> Enum.sort_by(&(Map.get(&1, "position") || 0))
        |> Enum.map(&Map.get(&1, "burpee_count"))
        |> Enum.reject(&is_nil/1)

      List.duplicate(motif, max(Map.get(block, "repeat_count", 1), 1))
    end)
    |> List.flatten()
    |> case do
      [] -> [10]
      pattern -> pattern
    end
  end

  defp source_block_pattern(_blocks), do: [10]

  defp maybe_put_unbroken_max(source, %{"pacing_style" => "unbroken"} = attrs, _block_pattern) do
    Map.put(
      source,
      "max_unbroken_reps",
      source_max_unbroken_reps(
        attrs,
        Map.get(attrs, "blocks", default_plan_blocks()),
        source["burpee_type"]
      )
    )
  end

  defp maybe_put_unbroken_max(source, _attrs, _block_pattern), do: source

  defp source_max_unbroken_reps(attrs, blocks, burpee_type) do
    Map.get(attrs, "max_unbroken_reps") ||
      blocks
      |> source_block_pattern()
      |> Enum.max(fn -> default_unbroken_source_set_size(burpee_type) end)
  end

  defp default_unbroken_source_set_size("navy_seal"), do: 5
  defp default_unbroken_source_set_size(_burpee_type), do: 8

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
