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
    field :max_set_reps, :integer
  end

  @type t :: %__MODULE__{}

  def from_definition(definition) do
    work = Enum.filter(definition["events"], &(&1["kind"] == "work"))

    pace =
      case Enum.uniq(Enum.map(work, &(&1["sec_per_burpee"] || &1["sec_per_rep"]))) do
        [pace] -> pace
        _ -> nil
      end

    seconds = round(definition["target_duration_sec"])

    %__MODULE__{
      burpee_type: definition["burpee_type"],
      pacing_style: definition["pacing_style"],
      reps: definition["target_reps"],
      duration:
        "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}",
      pace: pace
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
      :max_set_reps
    ])
    |> validate_required([:burpee_type, :pacing_style, :reps, :duration, :recovery])
    |> validate_inclusion(:burpee_type, ~w(six_count navy_seal))
    |> validate_inclusion(:pacing_style, ~w(even unbroken))
    |> validate_inclusion(:recovery, ~w(optional required forbidden))
    |> validate_number(:reps, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:pace, greater_than: 0, less_than_or_equal_to: 86_400)
    |> validate_number(:max_set_reps, greater_than: 0)
    |> validate_length(:note, max: 300)
    |> preflight()
  end

  defp preflight(%{valid?: false} = changeset), do: changeset

  defp preflight(changeset) do
    params = apply_changes(changeset)

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

    if String.length(instruction(params)) <= 500 and byte_size(instruction(params)) <= 4_000,
      do: changeset,
      else: add_error(changeset, :note, "Combined request is too long")
  end

  @doc "The request the fields make; sets and pauses come from the note, read by the coach."
  @spec request(t()) :: {:ok, WorkoutRequest.t()} | {:error, term()}
  def request(params) do
    with {:ok, seconds} <- CreationParameters.duration_seconds(params.duration) do
      WorkoutRequest.new(%{
        "burpee_type" => params.burpee_type,
        "pacing_style" => params.pacing_style,
        "target_reps" => params.reps,
        "target_duration_sec" => seconds,
        "recovery" => params.recovery,
        "timed_rests" => [],
        "requested_pace_sec" => params.pace,
        "max_set_reps" => params.max_set_reps
      })
    end
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
        max_set_reps: request.max_set_reps
    }
  end

  @prefix "Additional request: "

  @doc "What New's questions chose, in one line: `Six-count · Unbroken · 20 min · 75 reps · 4.5 s per rep`."
  @spec summary(t()) :: String.t()
  def summary(params) do
    {:ok, seconds} = CreationParameters.duration_seconds(params.duration)

    [
      CreationParameters.type_label(params.burpee_type),
      params.pacing_style |> String.capitalize(),
      "#{div(seconds, 60)} min",
      "#{params.reps} reps",
      if(params.max_set_reps, do: "sets of up to #{params.max_set_reps}"),
      if(params.pace,
        do: "#{:erlang.float_to_binary(params.pace * 1.0, decimals: 1)} s per rep",
        else: "coach picks the pace"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  The message New opens its chat with: the choices, then a line for anything else, ready to
  be written after.
  """
  @spec message(t(), String.t()) :: String.t()
  def message(params, note \\ ""), do: summary(params) <> "\n" <> @prefix <> note

  @doc "What the athlete wrote after the prefix; with the prefix gone, all of the message."
  @spec note(String.t()) :: String.t()
  def note(text) when is_binary(text) do
    case Regex.run(~r/additional request:[ \t]*(.*)\z/is, text) do
      [_, note] -> String.trim(note)
      nil -> String.trim(text)
    end
  end

  @spec instruction(t()) :: String.t()
  def instruction(params) do
    "New workout. Type: #{params.burpee_type}; style: #{params.pacing_style}; reps: #{params.reps}; duration: #{params.duration}; active pace: #{if(params.pace, do: "#{params.pace}s per rep", else: "coach chooses")}#{if(params.max_set_reps, do: "; no set longer than #{params.max_set_reps} reps")}. " <>
      String.trim(params.note || "")
  end
end
