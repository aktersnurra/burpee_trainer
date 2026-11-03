defmodule BurpeeTrainerWeb.NewWorkoutForm do
  @moduledoc """
  The New workout form: type, style, duration, reps, set size (unbroken only), pace and a note,
  on one screen. It opens on what `Coach.NewDefaults` suggests. Reps and pace follow the
  duration and type, and an unbroken set's size the reps, until the athlete sets them; the value being changed is capped at what the
  others leave room for, so reps stop where movement at the pace would fill the duration, and a
  change of duration or type lowers the reps when they no longer fit. Pure but for the suggested reps, which read the athlete's progression.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.NewDefaults
  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutRequest}

  @enforce_keys [:params, :touched]
  defstruct [:params, :touched]

  @type field :: String.t()
  @type t :: %__MODULE__{params: HomeWorkoutRequest.t(), touched: [field()]}

  # The order a submitted form is applied in: what the later values are suggested from first.
  @fields ~w(burpee_type pacing_style duration reps sets pace)

  @doc "The form on what is suggested for `params`' type, within the week's time left."
  @spec open(HomeWorkoutRequest.t(), Scope.t(), non_neg_integer() | nil) :: t()
  def open(params, scope, remaining_sec) do
    minutes = NewDefaults.default_duration(remaining_sec)
    params = %{params | duration: CreationParameters.duration_label(minutes * 60)}
    %__MODULE__{params: params |> suggest([], scope) |> fit_sets([]), touched: []}
  end

  @doc """
  `field` set to `value`, as typed or chosen. What does not parse, or parses to the value it
  already has, changes nothing.
  """
  @spec change(t(), field(), String.t(), Scope.t(), non_neg_integer() | nil) :: t()
  def change(%__MODULE__{} = form, "note", value, _scope, _remaining_sec) when is_binary(value),
    do: put_in(form.params.note, value)

  def change(%__MODULE__{} = form, field, value, scope, remaining_sec) do
    case parse(field, value, form.params, remaining_sec) do
      {:ok, parsed} ->
        if parsed == current(form.params, field), do: form, else: set(form, field, parsed, scope)

      :error ->
        form
    end
  end

  @doc "`field` one step up or down: five minutes, five reps, half a second, or a set size."
  @spec step(t(), field(), :up | :down, Scope.t(), non_neg_integer() | nil) :: t()
  def step(%__MODULE__{params: p} = form, field, direction, scope, remaining_sec) do
    value =
      case field do
        "duration" -> NewDefaults.step_duration(minutes(p), direction, remaining_sec)
        "reps" -> NewDefaults.step_reps(p.reps, direction)
        "sets" -> NewDefaults.step_set_size(p.max_set_reps, direction, p.reps)
        "pace" -> NewDefaults.step_pace(p.pace, direction, type(p))
      end

    if value == current(p, field), do: form, else: set(form, field, value, scope)
  end

  @doc "The submitted form, applied field by field: a value typed but not yet sent counts."
  @spec submit(t(), map(), Scope.t(), non_neg_integer() | nil) :: t()
  def submit(%__MODULE__{} = form, submitted, scope, remaining_sec) do
    form =
      Enum.reduce(@fields, form, fn field, form ->
        case submitted do
          %{^field => value} when is_binary(value) ->
            change(form, field, value, scope, remaining_sec)

          _ ->
            form
        end
      end)

    case submitted do
      %{"note" => note} when is_binary(note) -> change(form, "note", note, scope, remaining_sec)
      _ -> form
    end
  end

  # The value for `field`, parsed and kept within its own range.

  defp parse(field, value, _params, _remaining)
       when field in ~w(burpee_type pacing_style) and is_binary(value) do
    allowed = if field == "burpee_type", do: ~w(six_count navy_seal), else: ~w(even unbroken)
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp parse("duration", value, _params, remaining_sec) do
    with {:ok, minutes} <- integer(value) do
      options = NewDefaults.durations(remaining_sec)
      {:ok, minutes |> max(hd(options)) |> min(List.last(options))}
    end
  end

  defp parse("reps", value, _params, _remaining) do
    with {:ok, reps} <- integer(value), do: {:ok, max(reps, 1)}
  end

  defp parse("sets", "", _params, _remaining), do: {:ok, nil}

  defp parse("sets", value, params, _remaining) do
    with {:ok, size} <- integer(value), do: {:ok, set_size(max(size, 1), params.reps)}
  end

  defp parse("pace", value, params, _remaining) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {pace, ""} -> {:ok, pace |> Float.round(1) |> max(NewDefaults.min_pace(type(params)))}
      _ -> :error
    end
  end

  defp parse(_field, _value, _params, _remaining), do: :error

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp integer(_value), do: :error

  defp current(p, "burpee_type"), do: p.burpee_type
  defp current(p, "pacing_style"), do: p.pacing_style
  defp current(p, "duration"), do: minutes(p)
  defp current(p, "reps"), do: p.reps
  defp current(p, "sets"), do: p.max_set_reps
  defp current(p, "pace"), do: p.pace

  # Sets the value, re-suggests what follows it and is not the athlete's, then makes it fit.
  defp set(form, field, value, scope) do
    touched = Enum.uniq([field | form.touched])
    p = put(form.params, field, value)

    p = if field in ~w(burpee_type duration), do: suggest(p, touched, scope), else: p

    %__MODULE__{params: p |> fit(field) |> fit_sets(touched), touched: touched}
  end

  defp put(p, "burpee_type", v), do: %{p | burpee_type: v}
  defp put(p, "pacing_style", v), do: %{p | pacing_style: v}
  defp put(p, "duration", v), do: %{p | duration: CreationParameters.duration_label(v * 60)}
  defp put(p, "reps", v), do: %{p | reps: v}
  defp put(p, "sets", v), do: %{p | max_set_reps: v}
  defp put(p, "pace", v), do: %{p | pace: v}

  defp suggest(p, touched, scope) do
    p =
      if "reps" in touched,
        do: p,
        else: %{p | reps: NewDefaults.suggested_reps(scope, type(p), seconds(p))}

    if "pace" in touched,
      do: p,
      else: %{p | pace: NewDefaults.default_pace(type(p), p.reps, seconds(p))}
  end

  # Movement alone must fit the duration. A pace being changed is capped; otherwise the reps
  # give way.
  defp fit(p, field), do: p |> at_least_min_pace() |> fit_to_duration(field)

  # A pace set for one type can be faster than another allows.
  defp at_least_min_pace(p), do: %{p | pace: max(p.pace, NewDefaults.min_pace(type(p)))}

  defp fit_to_duration(p, "pace") do
    if p.reps * p.pace <= seconds(p) do
      p
    else
      pace = max(Float.floor(seconds(p) / p.reps, 1), NewDefaults.min_pace(type(p)))
      %{p | pace: pace, reps: min(p.reps, NewDefaults.max_reps(pace, seconds(p)))}
    end
  end

  defp fit_to_duration(p, _field),
    do: %{p | reps: min(p.reps, NewDefaults.max_reps(p.pace, seconds(p)))}

  # An unbroken set follows the reps until the athlete sets its size.
  defp fit_sets(%{pacing_style: "even"} = p, _touched), do: %{p | max_set_reps: nil}

  defp fit_sets(p, touched) do
    if "sets" in touched,
      do: %{p | max_set_reps: set_size(p.max_set_reps, p.reps)},
      else: %{p | max_set_reps: NewDefaults.default_set_size(p.reps)}
  end

  # A limit at or above the reps is no limit.
  defp set_size(nil, _reps), do: nil
  defp set_size(size, reps) when size >= reps, do: nil
  defp set_size(size, _reps), do: size

  defp seconds(p) do
    {:ok, seconds} = CreationParameters.duration_seconds(p.duration)
    seconds
  end

  defp minutes(p), do: div(seconds(p), 60)
  defp type(p), do: String.to_existing_atom(p.burpee_type)
end
