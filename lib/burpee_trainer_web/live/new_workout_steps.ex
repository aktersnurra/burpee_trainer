defmodule BurpeeTrainerWeb.NewWorkoutSteps do
  @moduledoc """
  The New workout's questions, one at a time: type, style, duration, reps, pace, then the
  message. Pure: each function takes the parameters chosen so far and returns them. A step
  starts from what `Coach.NewDefaults` suggests, and a value moves one step at a time.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.NewDefaults
  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutRequest}

  @answerable [:type, :style, :duration, :reps, :sets, :pace]

  @type step :: :type | :style | :duration | :reps | :sets | :pace | :ready | :request

  @doc """
  The questions to ask, in order: unbroken sets ask how large a set may be, which an even beat
  has no use for. Then `:ready` (what was chosen, to send or add to) and `:request` (the chat).
  """
  @spec questions(HomeWorkoutRequest.t()) :: [step()]
  def questions(params) do
    [:type, :style, :duration, :reps] ++
      if(params.pacing_style == "unbroken", do: [:sets], else: []) ++ [:pace]
  end

  @doc "The step a name from the client stands for, or `:error`."
  @spec parse(String.t()) :: {:ok, step()} | :error
  def parse(name) when is_binary(name) do
    case Enum.find(@answerable, &(Atom.to_string(&1) == name)) do
      nil -> :error
      step -> {:ok, step}
    end
  end

  def parse(_name), do: :error

  @doc "The step after `step`; `:ready` follows the last question."
  @spec next(step(), HomeWorkoutRequest.t()) :: step()
  def next(step, params) do
    order = questions(params) ++ [:ready, :request]
    index = Enum.find_index(order, &(&1 == step)) || length(order) - 1
    Enum.at(order, index + 1, :request)
  end

  @doc "The step before `step`; `:type` is the first."
  @spec previous(step(), HomeWorkoutRequest.t()) :: step()
  def previous(step, params) do
    order = questions(params) ++ [:ready, :request]
    index = Enum.find_index(order, &(&1 == step)) || 0
    Enum.at(order, max(index - 1, 0))
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

    %{
      params
      | reps: min(reps, NewDefaults.max_reps(pace, seconds)),
        pace: pace,
        max_set_reps: nil
    }
  end

  # Sets start unlimited; the athlete tightens them.
  def enter(params, :sets, _scope, _remaining_sec), do: %{params | max_set_reps: nil}

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

  def step(params, "sets", direction, _remaining_sec),
    do: %{
      params
      | max_set_reps: NewDefaults.step_set_size(params.max_set_reps, direction, params.reps)
    }

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
