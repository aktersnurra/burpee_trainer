defmodule BurpeeTrainer.Coach.AuthoritativeSession do
  @moduledoc "Canonical completed-session fact and immutable snapshot contract."

  @source_kinds [:plan, :video, :manual]

  @spec authoritative?(map()) :: boolean()
  def authoritative?(session) when is_map(session) do
    completed?(session) and
      valid_source_snapshot?(normalize_source(field(session, :source_kind)), session)
  end

  def authoritative?(_session), do: false

  @spec completed?(map()) :: boolean()
  def completed?(session) when is_map(session) do
    field(session, :state) in [:completed, "completed"] and
      match?({:ok, %DateTime{}}, normalize_datetime(field(session, :completed_at))) and
      normalize_source(field(session, :source_kind)) in @source_kinds
  end

  def completed?(_session), do: false

  @doc "True for an authoritative, confirmed, positive, non-warmup completed session."
  @spec confirmed_non_warmup?(map()) :: boolean()
  def confirmed_non_warmup?(session) when is_map(session) do
    authoritative?(session) and
      normalize_burpee_type(field(session, :burpee_type)) in [:six_count, :navy_seal] and
      positive_integer?(field(session, :burpee_count_actual)) and
      positive_integer?(field(session, :duration_sec_actual)) and
      field(session, :tags) != "warmup"
  end

  def confirmed_non_warmup?(_session), do: false

  @doc "PB eligibility is restricted to prescribed structured 20-minute plan sessions."
  @spec prescribed_plan_pb_eligible?(map()) :: boolean()
  def prescribed_plan_pb_eligible?(session) when is_map(session) do
    confirmed_non_warmup?(session) and normalize_source(field(session, :source_kind)) == :plan and
      field(session, :duration_sec_planned) == 1_200
  end

  def prescribed_plan_pb_eligible?(_session), do: false

  @spec within_window?(DateTime.t() | NaiveDateTime.t() | term(), DateTime.t(), DateTime.t()) ::
          boolean()
  def within_window?(value, %DateTime{} = lower_bound, %DateTime{} = now) do
    with {:ok, completed_at} <- normalize_datetime(value) do
      DateTime.compare(completed_at, lower_bound) in [:eq, :gt] and
        DateTime.compare(completed_at, now) in [:eq, :lt]
    else
      _invalid -> false
    end
  end

  def within_window?(_value, _lower_bound, _now), do: false

  @spec session_sort_key(map()) :: {integer(), integer()}
  def session_sort_key(session) when is_map(session) do
    {datetime_sort_key(field(session, :completed_at)),
     positive_integer_or_zero(field(session, :id))}
  end

  def session_sort_key(_session), do: {0, 0}

  @spec datetime_sort_key(DateTime.t() | NaiveDateTime.t() | term()) :: integer()
  def datetime_sort_key(value) do
    with {:ok, datetime} <- normalize_datetime(value) do
      DateTime.to_unix(datetime, :microsecond)
    else
      _invalid -> 0
    end
  end

  defp valid_source_snapshot?(:manual, session) do
    is_nil(field(session, :plan_id)) and is_nil(field(session, :workout_video_id)) and
      is_nil(field(session, :program_snapshot)) and is_nil(field(session, :video_snapshot))
  end

  defp valid_source_snapshot?(:plan, session) do
    is_nil(field(session, :workout_video_id)) and
      is_binary(field(session, :display_name_snapshot)) and
      (is_map(field(session, :program_snapshot)) or is_nil(field(session, :plan_id)))
  end

  defp valid_source_snapshot?(:video, session) do
    is_nil(field(session, :plan_id)) and is_map(field(session, :video_snapshot)) and
      is_binary(field(session, :display_name_snapshot))
  end

  defp valid_source_snapshot?(_source, _session), do: false

  defp normalize_source(value) when value in @source_kinds, do: value
  defp normalize_source("plan"), do: :plan
  defp normalize_source("video"), do: :video
  defp normalize_source("manual"), do: :manual
  defp normalize_source(_value), do: nil

  defp normalize_datetime(%DateTime{} = value), do: {:ok, value}
  defp normalize_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive(value, "Etc/UTC")
  defp normalize_datetime(_value), do: :error

  defp normalize_burpee_type(value) when value in [:six_count, "six_count"], do: :six_count
  defp normalize_burpee_type(value) when value in [:navy_seal, "navy_seal"], do: :navy_seal
  defp normalize_burpee_type(_value), do: nil

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp positive_integer_or_zero(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_zero(_value), do: 0
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
