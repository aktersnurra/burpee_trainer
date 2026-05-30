defmodule BurpeeTrainer.Workouts.Capture do
  @moduledoc """
  Capture-mode boundary for workout sessions.

  The database stores capture fields flatly. This module reconstructs the
  variant shape and rejects impossible combinations.
  """

  @type mode :: :tracked | :timed | :logged

  @type tracked :: %{
          mode: :tracked,
          cadence_ms: [non_neg_integer()],
          target_pace_sec: float() | nil,
          consistency: float()
        }

  @type timed :: %{
          mode: :timed,
          target_pace_sec: float() | nil
        }

  @type logged :: %{mode: :logged}
  @type t :: tracked | timed | logged

  @spec from_fields(map()) :: {:ok, t()} | {:error, atom()}
  def from_fields(fields) do
    mode = normalize_mode(Map.get(fields, :capture_mode) || Map.get(fields, "capture_mode"))
    cadence = Map.get(fields, :cadence_ms) || Map.get(fields, "cadence_ms")
    target = Map.get(fields, :target_pace_sec) || Map.get(fields, "target_pace_sec")
    consistency = Map.get(fields, :pace_consistency) || Map.get(fields, "pace_consistency")

    case mode do
      :tracked -> tracked(cadence, target, consistency)
      :timed -> timed(cadence, target, consistency)
      :logged -> logged(cadence, target, consistency)
      :invalid -> {:error, :invalid_capture_mode}
    end
  end

  defp normalize_mode(nil), do: :logged
  defp normalize_mode("tracked"), do: :tracked
  defp normalize_mode("timed"), do: :timed
  defp normalize_mode("logged"), do: :logged
  defp normalize_mode(:tracked), do: :tracked
  defp normalize_mode(:timed), do: :timed
  defp normalize_mode(:logged), do: :logged
  defp normalize_mode(_), do: :invalid

  defp tracked(nil, _target, _consistency), do: {:error, :tracked_missing_cadence}
  defp tracked(_cadence, _target, nil), do: {:error, :tracked_missing_consistency}

  defp tracked(cadence_json, target, consistency) do
    with {:ok, cadence} <- decode_cadence(cadence_json) do
      {:ok,
       %{
         mode: :tracked,
         cadence_ms: cadence,
         target_pace_sec: target,
         consistency: consistency
       }}
    end
  end

  defp timed(nil, target, nil), do: {:ok, %{mode: :timed, target_pace_sec: target}}
  defp timed(_cadence, _target, _consistency), do: {:error, :timed_has_cadence}

  defp logged(nil, nil, nil), do: {:ok, %{mode: :logged}}
  defp logged(_cadence, _target, _consistency), do: {:error, :logged_has_capture_data}

  defp decode_cadence(cadence) when is_list(cadence), do: validate_cadence(cadence)

  defp decode_cadence(cadence_json) when is_binary(cadence_json) do
    case Jason.decode(cadence_json) do
      {:ok, cadence} -> validate_cadence(cadence)
      _ -> {:error, :invalid_cadence_json}
    end
  end

  defp decode_cadence(_), do: {:error, :invalid_cadence_json}

  defp validate_cadence(cadence) when is_list(cadence) do
    if Enum.all?(cadence, &(is_integer(&1) and &1 >= 0)) do
      {:ok, cadence}
    else
      {:error, :invalid_cadence_values}
    end
  end

  defp validate_cadence(_), do: {:error, :invalid_cadence_json}
end
