defmodule BurpeeTrainerWeb.HomeWorkoutRequest do
  @moduledoc "Shared controls and local preflight for independently reviewed workouts."
  use Ecto.Schema
  import Ecto.Changeset
  alias BurpeeTrainer.Coach.{WorkoutRequest, WorkoutConfiguration}
  alias BurpeeTrainerWeb.CreationParameters

  @primary_key false
  embedded_schema do
    field :burpee_type, :string, default: "six_count"
    field :pacing_style, :string, default: "unbroken"
    field :reps, :integer, default: 120
    field :duration, :string, default: "20:00"
    field :note, :string, default: ""
    field :recovery, :string, default: "optional"
    field :pace, :float
    field :sets, :string, default: ""
    field :rests, :string, default: ""
  end

  @type t :: %__MODULE__{}

  def from_definition(definition) do
    work = Enum.filter(definition["events"], &(&1["kind"] == "work"))

    pace =
      case Enum.uniq(Enum.map(work, &(&1["sec_per_burpee"] || &1["sec_per_rep"]))) do
        [pace] -> pace
        _ -> nil
      end

    sets =
      work
      |> Enum.map(& &1["reps"])
      |> Enum.chunk_by(& &1)
      |> Enum.map_join(",", fn reps -> "#{length(reps)}x#{hd(reps)}" end)

    seconds = round(definition["target_duration_sec"])

    %__MODULE__{
      burpee_type: definition["burpee_type"],
      pacing_style: definition["pacing_style"],
      reps: definition["target_reps"],
      duration:
        "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}",
      pace: pace,
      sets: sets
    }
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(params, attrs) do
    params
    |> cast(attrs, [
      :burpee_type,
      :pacing_style,
      :reps,
      :duration,
      :note,
      :recovery,
      :pace,
      :sets,
      :rests
    ])
    |> validate_required([:burpee_type, :pacing_style, :reps, :duration, :recovery])
    |> validate_inclusion(:burpee_type, ~w(six_count navy_seal))
    |> validate_inclusion(:pacing_style, ~w(even unbroken))
    |> validate_inclusion(:recovery, ~w(optional required forbidden))
    |> validate_number(:reps, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:pace, greater_than: 0, less_than_or_equal_to: 86_400)
    |> validate_length(:note, max: 300)
    |> validate_length(:sets, max: 300)
    |> validate_length(:rests, max: 300)
    |> preflight()
  end

  defp preflight(%{valid?: false} = changeset), do: changeset

  defp preflight(changeset) do
    params = apply_changes(changeset)

    changeset =
      case WorkoutConfiguration.parse_sets(params.sets) do
        {:ok, []} ->
          changeset

        {:ok, sets} ->
          if Enum.sum(sets) == params.reps,
            do: changeset,
            else:
              add_error(
                changeset,
                :sets,
                "Pattern contains #{Enum.sum(sets)} reps; total is #{params.reps}"
              )

        _ ->
          add_error(changeset, :sets, "Use 5x8, 5x7, 5x(7,6)")
      end

    changeset =
      case CreationParameters.duration_seconds(params.duration) do
        {:ok, duration} ->
          case WorkoutConfiguration.budget(params.reps, params.pace, duration) do
            {:ok, _} -> changeset
            _ -> add_error(changeset, :pace, "Movement alone exceeds the duration")
          end

        _ ->
          add_error(changeset, :duration, "Use minutes:seconds (0:01–1440:00)")
      end

    changeset =
      case request(params) do
        {:ok, _} ->
          changeset

        {:error, :invalid_rests} ->
          add_error(
            changeset,
            :rests,
            "Use 60s at 11:00; pauses must not overlap or exceed the duration"
          )

        _ ->
          if changeset.valid?,
            do: add_error(changeset, :rests, "Check pause times, duration and recovery"),
            else: changeset
      end

    if String.length(instruction(params)) <= 500 and byte_size(instruction(params)) <= 4_000,
      do: changeset,
      else: add_error(changeset, :sets, "Combined request is too long")
  end

  @spec request(t(), WorkoutRequest.t() | nil) :: {:ok, WorkoutRequest.t()} | {:error, term()}
  def request(params, extracted \\ nil) do
    with {:ok, seconds} <- CreationParameters.duration_seconds(params.duration),
         {:ok, sets} <- WorkoutConfiguration.parse_sets(params.sets),
         {:ok, rests} <- WorkoutConfiguration.parse_rests(params.rests) do
      base =
        if extracted,
          do: WorkoutRequest.to_map(extracted),
          else: %{
            "recovery" => params.recovery,
            "timed_rests" => rests,
            "requested_pace_sec" => params.pace
          }

      WorkoutRequest.new(
        Map.merge(base, %{
          "burpee_type" => params.burpee_type,
          "pacing_style" => params.pacing_style,
          "target_reps" => params.reps,
          "target_duration_sec" => seconds,
          "set_reps" => sets
        })
      )
    end
  end

  @spec budget(t()) :: {:ok, map() | :unknown_pace} | {:error, atom()}
  def budget(params) do
    with {:ok, seconds} <- CreationParameters.duration_seconds(params.duration),
         do: WorkoutConfiguration.budget(params.reps, params.pace, seconds)
  end

  @spec from_request(WorkoutRequest.t(), t()) :: t()
  def from_request(request, previous) do
    %{
      previous
      | burpee_type: request.burpee_type,
        pacing_style: request.pacing_style,
        reps: request.target_reps,
        duration: CreationParameters.duration_label(request.target_duration_sec),
        recovery: request.recovery,
        pace: request.requested_pace_sec,
        sets:
          if(String.trim(previous.sets || "") == "",
            do:
              request.set_reps
              |> Enum.chunk_by(& &1)
              |> Enum.map_join(", ", &"#{length(&1)}x#{hd(&1)}"),
            else: previous.sets
          ),
        rests:
          Enum.map_join(
            request.timed_rests,
            "\n",
            &"#{&1.duration_sec}s at #{CreationParameters.duration_label(&1.start_sec)}"
          )
    }
  end

  @spec instruction(t()) :: String.t()
  def instruction(params) do
    "New workout. Type: #{params.burpee_type}; style: #{params.pacing_style}; reps: #{params.reps}; duration: #{params.duration}; active pace: #{if(params.pace, do: "#{params.pace}s per rep", else: "coach chooses")}; sets: #{params.sets || "coach chooses"}; total pauses: #{params.rests || "coach chooses"}. " <>
      String.trim(params.note || "")
  end
end
