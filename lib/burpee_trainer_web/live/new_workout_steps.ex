defmodule BurpeeTrainerWeb.NewWorkoutSteps do
  @moduledoc """
  The New workout's questions, one at a time: type, style, duration, reps, pace, then the
  message. Pure: each function takes the parameters chosen so far and returns them. A step
  starts from what `Coach.NewDefaults` suggests, and a value moves one step at a time.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.NewDefaults
  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutRequest}

  @steps [:type, :style, :duration, :reps, :pace, :ready]
  @answerable @steps -- [:ready]

  @type step :: :type | :style | :duration | :reps | :pace | :ready

  @spec steps() :: [step()]
  def steps, do: @steps

  @doc "The step a name from the client stands for, or `:error`."
  @spec parse(String.t()) :: {:ok, step()} | :error
  def parse(name) when is_binary(name) do
    case Enum.find(@answerable, &(Atom.to_string(&1) == name)) do
      nil -> :error
      step -> {:ok, step}
    end
  end

  def parse(_name), do: :error

  @doc "The step after `step`; `:ready` is the last."
  @spec next(step()) :: step()
  def next(step) do
    index = Enum.find_index(@steps, &(&1 == step))
    Enum.at(@steps, index + 1, :ready)
  end

  @doc "The parameters on entering `step`: what it is suggested to start from."
  @spec enter(HomeWorkoutRequest.t(), step(), Scope.t(), non_neg_integer() | nil) ::
          HomeWorkoutRequest.t()
  def enter(params, :duration, _scope, remaining_sec) do
    minutes = NewDefaults.default_duration(remaining_sec)
    %{params | duration: CreationParameters.duration_label(minutes * 60)}
  end

  def enter(params, :reps, scope, _remaining_sec) do
    type = burpee_type(params)
    seconds = seconds(params)
    reps = NewDefaults.suggested_reps(scope, type, seconds)
    pace = NewDefaults.default_pace(type, reps, seconds)
    %{params | reps: min(reps, NewDefaults.max_reps(pace, seconds)), pace: pace}
  end

  def enter(params, :pace, _scope, _remaining_sec) do
    %{params | pace: NewDefaults.default_pace(burpee_type(params), params.reps, seconds(params))}
  end

  def enter(params, _step, _scope, _remaining_sec), do: params

  @doc """
  One step up or down in `field`. A value never leaves what the week and the others allow:
  durations stay within the time left, and reps and pace within the duration.
  """
  @spec step(HomeWorkoutRequest.t(), String.t(), :up | :down, non_neg_integer() | nil) ::
          HomeWorkoutRequest.t()
  def step(params, "duration", direction, remaining_sec) do
    minutes = NewDefaults.step_duration(div(seconds(params), 60), direction, remaining_sec)
    %{params | duration: CreationParameters.duration_label(minutes * 60)}
  end

  def step(params, "reps", direction, _remaining_sec) do
    seconds = seconds(params)
    pace = params.pace || NewDefaults.default_pace(burpee_type(params), params.reps, seconds)
    reps = NewDefaults.step_reps(params.reps, direction)

    if reps * pace <= seconds, do: %{params | reps: reps}, else: params
  end

  def step(params, "pace", direction, _remaining_sec) do
    pace = NewDefaults.step_pace(params.pace, direction)
    if params.reps * pace <= seconds(params), do: %{params | pace: pace}, else: params
  end

  defp seconds(params) do
    {:ok, seconds} = CreationParameters.duration_seconds(params.duration)
    seconds
  end

  defp burpee_type(params), do: String.to_existing_atom(params.burpee_type)
end
