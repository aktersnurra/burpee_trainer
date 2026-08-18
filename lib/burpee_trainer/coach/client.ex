defmodule BurpeeTrainer.Coach.Client do
  @moduledoc "One-call Req boundary for structured workout authoring."

  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.Error

  require Logger

  @max_response_bytes 262_144
  @max_output_tokens 16_384
  @default_timeout_ms 20_000
  @minimum_timeout_ms 1_000
  @maximum_timeout_ms 60_000
  @inherited_response_options [
    :follow_redirects,
    :redirect,
    :redirect_trusted,
    :redirect_log_level,
    :max_redirects,
    :retry,
    :retry_delay,
    :retry_log_level,
    :max_retries,
    :raw,
    :decode_body,
    :decode_json,
    :http_errors,
    :output
  ]

  @spec complete([map()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def complete(messages, opts \\ [])

  def complete(messages, opts) when is_list(messages) and is_list(opts) do
    config = Keyword.get(opts, :config, Application.get_env(:burpee_trainer, :llm_provider, []))

    if is_list(config) do
      complete_with_config(messages, opts, config)
    else
      provider_unavailable()
    end
  rescue
    _error in [ArgumentError, Jason.EncodeError, Protocol.UndefinedError] ->
      provider_unavailable()
  end

  defp complete_with_config(messages, opts, config) do
    with :ok <- require_enabled(config),
         {:ok, url} <- required(config, :url),
         :ok <- validate_url(url),
         {:ok, api_key} <- required(config, :api_key),
         {:ok, model} <- required(config, :model),
         {:ok, response} <-
           Req.post(req(opts),
             url: url,
             auth: {:bearer, api_key},
             retry: false,
             redirect: false,
             decode_body: false,
             http_errors: :return,
             receive_timeout: timeout_ms(config),
             into: bounded_body(@max_response_bytes),
             json: %{
               model: model,
               max_tokens: @max_output_tokens,
               temperature: 0,
               response_format: %{
                 type: "json_schema",
                 json_schema: %{
                   name: "workout_definition",
                   strict: true,
                   schema: WorkoutDefinition.json_schema()
                 }
               },
               messages: messages
             }
           ),
         body when is_binary(body) <- response.body,
         :ok <- enforce_body_limit(body, @max_response_bytes),
         200 <- response.status,
         {:ok, content} <- response_content(body),
         {:ok, decoded} <- decode_content(content) do
      {:ok, decoded}
    else
      false ->
        provider_unavailable()

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.new(:provider_timeout)}

      {:error, %Req.TransportError{}} ->
        provider_unavailable()

      {:error, :invalid_configuration} ->
        provider_unavailable()

      {:error, reason}
      when reason in [:invalid_provider_response, :response_too_large] ->
        invalid_provider_response()

      {:error, _safe_provider_error} ->
        provider_unavailable()

      status when is_integer(status) ->
        {:error, Error.new(:provider_unavailable, %{status: status})}

      _invalid ->
        invalid_provider_response()
    end
  end

  defp require_enabled(config) do
    if Keyword.get(config, :enabled, false) === true,
      do: :ok,
      else: {:error, :provider_disabled}
  end

  defp required(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :invalid_configuration}
          trimmed -> {:ok, trimmed}
        end

      _missing ->
        {:error, :invalid_configuration}
    end
  end

  defp validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _invalid ->
        {:error, :invalid_configuration}
    end
  end

  defp timeout_ms(config) do
    case Keyword.get(config, :timeout_ms, @default_timeout_ms) do
      value
      when is_integer(value) and value >= @minimum_timeout_ms and value <= @maximum_timeout_ms ->
        value

      _invalid ->
        @default_timeout_ms
    end
  end

  defp req(opts) do
    request =
      case Keyword.get(opts, :req) do
        %Req.Request{} = request -> request
        _missing_or_invalid -> Req.new()
      end

    request =
      Enum.reduce(@inherited_response_options, request, fn option, request ->
        Req.Request.delete_option(request, option)
      end)

    %{request | into: nil}
  end

  defp enforce_body_limit(body, limit) do
    if byte_size(body) <= limit, do: :ok, else: {:error, :response_too_large}
  end

  defp response_content(body) do
    case decode_unique_json(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, envelope} ->
        log_rejected_envelope(envelope)
        {:error, :invalid_provider_response}

      {:error, :invalid_provider_response} = error ->
        Logger.warning("llm_provider_response_rejected stage=response_json")
        error
    end
  end

  defp decode_content(content) do
    case decode_unique_json(content) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      _invalid ->
        Logger.warning(
          "llm_provider_response_rejected stage=content_json content_bytes=#{byte_size(content)}"
        )

        {:error, :invalid_provider_response}
    end
  end

  defp log_rejected_envelope(envelope) do
    choice =
      case envelope do
        %{"choices" => [choice | _]} when is_map(choice) -> choice
        _other -> %{}
      end

    message = if is_map(choice["message"]), do: choice["message"], else: %{}

    Logger.warning(
      "llm_provider_response_rejected stage=envelope " <>
        "finish_reason=#{safe_finish_reason(choice["finish_reason"])} " <>
        "content_type=#{safe_json_type(message["content"])} " <>
        "refusal=#{if Map.has_key?(message, "refusal"), do: "present", else: "absent"}"
    )
  end

  defp safe_finish_reason(value)
       when value in ["stop", "length", "content_filter", "tool_calls", "error"],
       do: value

  defp safe_finish_reason(nil), do: "none"
  defp safe_finish_reason(_other), do: "other"

  defp safe_json_type(nil), do: "nil"
  defp safe_json_type(value) when is_binary(value), do: "string"
  defp safe_json_type(value) when is_map(value), do: "object"
  defp safe_json_type(value) when is_list(value), do: "array"
  defp safe_json_type(value) when is_number(value), do: "number"
  defp safe_json_type(value) when is_boolean(value), do: "boolean"
  defp safe_json_type(_other), do: "other"

  defp decode_unique_json(json) do
    with {:ok, decoded} <- Jason.decode(json, objects: :ordered_objects),
         {:ok, decoded} <- unique_json_value(decoded) do
      {:ok, decoded}
    else
      _invalid_or_duplicate -> {:error, :invalid_provider_response}
    end
  end

  defp unique_json_value(%Jason.OrderedObject{values: values}) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, object} ->
      if Map.has_key?(object, key) do
        {:halt, {:error, :duplicate_json_key}}
      else
        case unique_json_value(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(object, key, value)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
  end

  defp unique_json_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case unique_json_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp unique_json_value(value), do: {:ok, value}

  defp bounded_body(limit) do
    fn {:data, chunk}, {request, response} when is_binary(chunk) ->
      body = if is_binary(response.body), do: response.body, else: ""

      if byte_size(body) + byte_size(chunk) > limit do
        {:halt, {request, %{response | body: {:error, :response_too_large}}}}
      else
        {:cont, {request, %{response | body: body <> chunk}}}
      end
    end
  end

  defp provider_unavailable, do: {:error, Error.new(:provider_unavailable)}
  defp invalid_provider_response, do: {:error, Error.new(:invalid_provider_response)}
end
