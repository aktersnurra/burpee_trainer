defmodule BurpeeTrainer.Coach.Client do
  @moduledoc "Metered Req boundary for chat, strict output, tool calls, and typed decisions."

  alias BurpeeTrainer.Accounts.{Scope, User}
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

  @spec chat([map()], keyword()) ::
          {:ok, %{tool_calls: [map()], content: map() | String.t() | nil, usage: map()}}
          | {:error, Error.t()}
  def chat(messages, opts) when is_list(messages) and is_list(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    config = Keyword.get(opts, :config, Application.get_env(:burpee_trainer, :llm_provider, []))
    model = if is_list(config), do: Keyword.get(config, :model) || "unknown", else: "unknown"
    attrs = %{purpose: ledger.purpose, run_id: ledger.run_id, model: model}

    # A disabled provider, or a user coached over MCP, makes no call, so it neither records
    # nor spends budget.
    with true <- is_list(config) and require_enabled(config) == :ok,
         :app <- coach(ledger.scope),
         {:ok, call} <-
           BurpeeTrainer.Coach.Ledger.reserve(ledger.scope, attrs, Keyword.get(opts, :budget, [])) do
      record(ledger, call, fn -> chat_request(messages, opts, config) end)
    else
      false ->
        provider_unavailable()

      :mcp ->
        {:error, Error.new(:mcp_coach)}

      {:error, :llm_budget_exhausted} ->
        {:error, Error.new(:llm_budget_exhausted)}
    end
  end

  @doc """
  Asks a decision model typed `questions` about `state` through the Decisions API: no text
  comes back, only an answer per question. Metered like `chat/2`, from the `:decisions`
  provider config.
  """
  @spec decide(map() | list() | String.t(), map(), keyword()) ::
          {:ok, %{answers: map(), usage: map()}} | {:error, Error.t()}
  def decide(state, questions, opts) when is_map(questions) and is_list(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    config = Keyword.get(opts, :config, Application.get_env(:burpee_trainer, :decisions, []))
    model = if is_list(config), do: Keyword.get(config, :model) || "unknown", else: "unknown"
    attrs = %{purpose: ledger.purpose, run_id: ledger.run_id, model: model}

    with true <- is_list(config) and require_enabled(config) == :ok,
         :app <- coach(ledger.scope),
         {:ok, call} <-
           BurpeeTrainer.Coach.Ledger.reserve(ledger.scope, attrs, Keyword.get(opts, :budget, [])) do
      record(ledger, call, fn -> decide_request(state, questions, opts, config) end)
    else
      false ->
        provider_unavailable()

      :mcp ->
        {:error, Error.new(:mcp_coach)}

      {:error, :llm_budget_exhausted} ->
        {:error, Error.new(:llm_budget_exhausted)}
    end
  end

  defp record(ledger, call, request) do
    started = System.monotonic_time(:millisecond)

    {result, error_usage} =
      case request.() do
        {:error, error, usage} -> {{:error, error}, usage}
        result -> {result, %{}}
      end

    {outcome, usage} = outcome(result, error_usage)

    # Chat reports prompt and completion tokens; the Decisions API, input and output tokens.
    :ok =
      BurpeeTrainer.Coach.Ledger.finish(ledger.scope, call.id, %{
        outcome: outcome,
        prompt_tokens: token_usage(usage["prompt_tokens"] || usage["input_tokens"]),
        completion_tokens: token_usage(usage["completion_tokens"] || usage["output_tokens"]),
        cost_usd: cost_usage(usage["cost"]),
        duration_ms: System.monotonic_time(:millisecond) - started
      })

    result
  end

  defp outcome({:ok, %{tool_calls: [_ | _], usage: usage}}, _), do: {"tool_calls", usage}
  defp outcome({:ok, %{usage: usage}}, _), do: {"ok", usage}
  defp outcome({:error, %{code: :provider_timeout}}, usage), do: {"timeout", usage}

  defp outcome({:error, %{code: :invalid_provider_response}}, usage),
    do: {"invalid_response", usage}

  defp outcome({:error, _}, usage), do: {"provider_error", usage}

  defp token_usage(value) when is_integer(value) and value >= 0, do: value
  defp token_usage(_), do: nil
  defp cost_usage(value) when is_number(value) and value >= 0, do: value * 1.0
  defp cost_usage(_), do: nil

  defp chat_request(messages, opts, config),
    do:
      provider_request(
        config,
        opts,
        &encode_chat(messages, &1, &2, opts),
        &parse_chat_with_usage(&1, opts)
      )

  defp decide_request(state, questions, opts, config),
    do:
      provider_request(
        config,
        opts,
        fn model, _url -> encode_decision(state, questions, model) end,
        &parse_decision/1
      )

  # OpenRouter names the app in its logs from these; without a URL a request is an unknown
  # app. Hidden keeps it out of OpenRouter's public app listings.
  defp attribution(config) do
    case Keyword.get(config, :app_url) do
      url when is_binary(url) and url != "" ->
        [
          {"http-referer", url},
          {"x-openrouter-title", "BurpeeTrainer"},
          {"x-openrouter-app-visibility", "hidden"}
        ]

      _no_url ->
        []
    end
  end

  defp provider_request(config, opts, encode, parse) do
    with true <- is_list(config),
         :ok <- require_enabled(config),
         {:ok, url} <- required(config, :url),
         :ok <- validate_url(url),
         {:ok, key} <- required(config, :api_key),
         {:ok, model} <- required(config, :model),
         {:ok, encoded} <- encode.(model, url),
         {:ok, response} <-
           Req.post(req(opts),
             url: url,
             auth: {:bearer, key},
             retry: false,
             redirect: false,
             decode_body: false,
             http_errors: :return,
             receive_timeout: timeout_ms(config),
             into: bounded_body(@max_response_bytes),
             body: encoded,
             headers: [{"content-type", "application/json"} | attribution(config)]
           ),
         body when is_binary(body) <- response.body,
         :ok <- enforce_body_limit(body, @max_response_bytes),
         :ok <- chat_status(response.status, body),
         {:ok, parsed} <- parse.(body) do
      {:ok, parsed}
    else
      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.new(:provider_timeout)}

      {:error, %Error{} = error, usage} ->
        {:error, error, usage}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} when reason in [:invalid_provider_response, :response_too_large] ->
        invalid_provider_response()

      {:error, :provider_disabled} ->
        provider_unavailable()

      {:error, :invalid_configuration} ->
        provider_unavailable()

      status when is_integer(status) ->
        {:error, Error.new(:provider_unavailable, %{status: status})}

      {:error, _} ->
        provider_unavailable()

      false ->
        provider_unavailable()

      _ ->
        invalid_provider_response()
    end
  end

  defp chat_status(200, _body), do: :ok

  defp chat_status(status, body),
    do: {:error, Error.new(:provider_unavailable, %{status: status}), billing_usage(body)}

  defp parse_chat_with_usage(body, opts) do
    case parse_chat(body, opts) do
      {:error, :invalid_provider_response} ->
        {:error, Error.new(:invalid_provider_response), billing_usage(body)}

      result ->
        result
    end
  end

  defp billing_usage(body) do
    case decode_unique_json(body) do
      {:ok, %{"usage" => usage}} when is_map(usage) ->
        Map.take(usage, [
          "prompt_tokens",
          "completion_tokens",
          "input_tokens",
          "output_tokens",
          "cost"
        ])

      _ ->
        %{}
    end
  end

  defp encode_chat(messages, model, url, opts) do
    body = %{
      model: model,
      max_tokens: @max_output_tokens,
      messages: messages,
      usage: %{include: true}
    }

    body =
      case Keyword.get(opts, :tools, []) do
        [] ->
          body

        tools ->
          Map.put(
            body,
            :tools,
            Enum.map(tools, fn t ->
              %{
                type: "function",
                function: %{
                  name: t.name,
                  description: t.description,
                  parameters: t.schema,
                  strict: true
                }
              }
            end)
          )
      end

    body =
      case Keyword.get(opts, :response_format) do
        nil ->
          body

        {name, schema} ->
          Map.put(body, :response_format, %{
            type: "json_schema",
            json_schema: %{name: name, strict: true, schema: schema}
          })
      end

    body =
      if URI.parse(url).host == "openrouter.ai",
        do: Map.put(body, :provider, %{require_parameters: true}),
        else: Map.put(body, :temperature, 0)

    encoded = Jason.encode!(body)

    if byte_size(encoded) <= @max_response_bytes,
      do: {:ok, encoded},
      else: {:error, Error.new(:authoring_context_too_large)}
  end

  defp encode_decision(state, questions, model) do
    encoded = Jason.encode!(%{model: model, state: state, questions: questions})

    if byte_size(encoded) <= @max_response_bytes,
      do: {:ok, encoded},
      else: {:error, Error.new(:authoring_context_too_large)}
  end

  defp parse_decision(body) do
    case decode_unique_json(body) do
      {:ok, %{"answers" => answers, "usage" => usage}} when is_map(answers) and is_map(usage) ->
        {:ok, %{answers: answers, usage: usage}}

      _ ->
        Logger.warning("decision_provider_response_rejected stage=response_json")
        {:error, Error.new(:invalid_provider_response), billing_usage(body)}
    end
  end

  defp parse_chat(body, opts) do
    case decode_unique_json(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        :ok

      {:ok, %{"choices" => [%{"message" => %{"tool_calls" => [_ | _]}} | _]}} ->
        :ok

      {:ok, envelope} ->
        log_rejected_envelope(envelope)

      _ ->
        Logger.warning("llm_provider_response_rejected stage=response_json")
    end

    with {:ok, %{"choices" => [%{"message" => message} | _]} = decoded} <-
           decode_unique_json(body),
         true <- is_map(message) and is_nil(message["refusal"]),
         {:ok, calls} <- parse_calls(Map.get(message, "tool_calls") || []),
         {:ok, content} <- chat_content(message["content"], Keyword.get(opts, :response_format)),
         usage = Map.get(decoded, "usage") || %{},
         true <- is_map(usage) do
      {:ok, %{tool_calls: calls, content: content, usage: usage}}
    else
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp parse_calls(calls) when is_list(calls) and length(calls) <= 32 do
    Enum.reduce_while(calls, {:ok, []}, fn
      %{"id" => id, "function" => %{"name" => name, "arguments" => args}}, {:ok, acc}
      when is_binary(id) and is_binary(name) and is_binary(args) ->
        case decode_unique_json(args) do
          {:ok, %{} = arguments} ->
            {:cont, {:ok, acc ++ [%{id: id, name: name, arguments: arguments}]}}

          _ ->
            {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp parse_calls(_), do: :error
  defp chat_content(nil, _), do: {:ok, nil}
  defp chat_content(content, nil) when is_binary(content), do: {:ok, content}

  defp chat_content(content, {_name, _schema}) when is_binary(content),
    do: decode_content(content)

  defp chat_content(_, _), do: :error

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

  defp coach(%Scope{user: %User{coach: coach}}), do: coach

  defp provider_unavailable, do: {:error, Error.new(:provider_unavailable)}
  defp invalid_provider_response, do: {:error, Error.new(:invalid_provider_response)}
end
