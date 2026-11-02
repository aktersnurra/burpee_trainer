defmodule BurpeeTrainer.Coach.ClientTest do
  use BurpeeTrainer.DataCase, async: false

  import ExUnit.CaptureLog

  alias BurpeeTrainer.Coach.Client
  alias BurpeeTrainer.Coach.LlmCall
  alias BurpeeTrainer.ReqStub
  alias BurpeeTrainer.Workouts.Error

  test "oversized serialized request fails before HTTP" do
    parent = self()

    req =
      ReqStub.attach(
        Req.new(),
        fn request ->
          send(parent, :unexpected_http)
          {request, %Req.Response{status: 500, body: ""}}
        end
      )

    assert {:error, %Error{code: :authoring_context_too_large}} =
             structured_chat(
               [%{role: "user", content: String.duplicate("x", 262_145)}],
               req: req,
               response_kind: :workout_request,
               config: [
                 enabled: true,
                 url: "https://provider.test/v1",
                 api_key: "test",
                 model: "test"
               ]
             )

    refute_received :unexpected_http
  end

  test "schema envelope pushes otherwise bounded messages over the request cap", %{
    counter: counter
  } do
    messages = [%{role: "user", content: String.duplicate("x", 262_000)}]
    assert byte_size(Jason.encode!(messages)) < 262_144
    req = request(counter, fn conn -> json_response(conn, 200, %{}) end)

    assert {:error, %Error{code: :authoring_context_too_large}} =
             structured_chat(messages, opts(req))

    assert requests(counter) == []
  end

  @max_response_bytes 262_144

  setup do
    counter = start_supervised!({Agent, fn -> %{count: 0, requests: []} end})
    %{counter: counter}
  end

  test "OpenRouter requests require a provider supporting every requested parameter", %{
    counter: counter
  } do
    definition = definition("Schema-capable route")
    req = request(counter, fn conn -> json_response(conn, 200, definition) end)

    options =
      Keyword.update!(opts(req), :config, fn config ->
        config
        |> Keyword.put(:url, "https://openrouter.ai/api/v1/chat/completions")
        |> Keyword.put(:model, "openai/gpt-6-luna-pro")
      end)

    assert {:ok, ^definition} = structured_chat([], options)

    [recorded] = requests(counter)
    assert recorded.body["model"] == "openai/gpt-6-luna-pro"
    assert recorded.body["provider"] == %{"require_parameters" => true}
    refute Map.has_key?(recorded.body, "temperature")
    assert recorded.body["response_format"]["json_schema"]["strict"] == true
  end

  test "missing structured content logs safe completion diagnostics", %{counter: counter} do
    req =
      request(counter, fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "choices" => [
              %{"finish_reason" => "length", "message" => %{"content" => nil}}
            ]
          })
        )
      end)

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %Error{code: :invalid_provider_response, context: %{}}} =
                 structured_chat([%{role: "user", content: "private"}], opts(req))
      end)

    assert log =~ "llm_provider_response_rejected"
    assert log =~ "stage=envelope"
    assert log =~ "finish_reason=length"
    assert log =~ "content_type=nil"
    refute log =~ "private"
  end

  test "a disabled or incomplete provider config makes no request; a disabled one records no call",
       %{counter: counter} do
    req = request(counter, fn conn -> json_response(conn, 200, definition("unused")) end)
    credentials = [url: "https://provider.test/v1", api_key: "secret", model: "test/model"]

    disabled =
      for enabled <- [nil, false, 1, 0, "true", %{}, []],
          do: {[{:enabled, enabled} | credentials], :no_call}

    incomplete =
      for config <- [
            [enabled: true, url: "https://provider.test/v1", api_key: "secret"],
            [enabled: true, url: "https://provider.test/v1", model: "test/model"],
            [enabled: true, api_key: "secret", model: "test/model"],
            [enabled: true, url: " ", api_key: "secret", model: "test/model"]
          ],
          do: {config, :may_record}

    for {config, ledger} <-
          [{[enabled: false, url: nil, api_key: nil, model: nil], :no_call}] ++
            disabled ++ incomplete do
      calls_before = Repo.aggregate(LlmCall, :count)

      assert {:error, %Error{code: :provider_unavailable}} =
               structured_chat([], req: req, config: config)

      if ledger == :no_call, do: assert(Repo.aggregate(LlmCall, :count) == calls_before)
    end

    assert request_count(counter) == 0
  end

  test "timeouts and transport failures are safely normalized without raw reasons", %{
    counter: counter
  } do
    timeout_req = request(counter, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Error{code: :provider_timeout, context: %{}}} =
             structured_chat([], opts(timeout_req))

    transport_req = request(counter, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Error{code: :provider_unavailable, context: %{}}} =
             structured_chat([], opts(transport_req))

    assert request_count(counter) == 2
  end

  test "unexpected Req errors are normalized without leaking their message" do
    req =
      ReqStub.attach(Req.new(), fn request ->
        {request, RuntimeError.exception("raw-secret-error")}
      end)

    assert {:error, %Error{code: :provider_unavailable, context: %{}} = error} =
             structured_chat([], opts(req))

    refute inspect(error) =~ "raw-secret-error"
  end

  test "redirects and status failures are not followed or retried and leak no body", %{
    counter: counter
  } do
    statuses = [201, 204, 301, 307, 400, 404, 429, 500, 503, 599]

    for status <- statuses do
      req =
        request(counter, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://provider.test/second-request")
          |> Plug.Conn.send_resp(status, "raw-secret-provider-body")
        end)

      assert {:error, %Error{code: :provider_unavailable, context: %{status: ^status}} = error} =
               structured_chat([], opts(req))

      refute inspect(error) =~ "raw-secret-provider-body"
    end

    assert request_count(counter) == length(statuses)
  end

  test "the final body cap applies to an adapter that ignores into, at any status" do
    valid_body = provider_body(definition("raw-secret"))

    oversized_body =
      valid_body <> String.duplicate(" ", @max_response_bytes + 1 - byte_size(valid_body))

    for status <- [200, 302, 503] do
      req =
        ReqStub.attach(Req.new(), fn request ->
          {request, %Req.Response{status: status, body: oversized_body}}
        end)

      assert {:error, %Error{code: :invalid_provider_response, context: %{}} = error} =
               structured_chat([], opts(req))

      refute inspect(error) =~ "raw-secret"
    end
  end

  test "duplicate keys in provider envelopes and content are rejected", %{counter: counter} do
    duplicate_bodies = [
      ~s({"choices":[],"choices":[{"message":{"content":"{}"}}]}),
      ~s({"choices":[{"message":{"content":"{}","content":"{}"}}]}),
      ~s({"choices":[{"message":{"content":"{\\"version\\":1,\\"version\\":1}"}}]})
    ]

    for body <- duplicate_bodies do
      req = request(counter, &Plug.Conn.send_resp(&1, 200, body))

      assert {:error, %Error{code: :invalid_provider_response, context: %{}}} =
               structured_chat([], opts(req))
    end

    assert request_count(counter) == length(duplicate_bodies)
  end

  test "malformed envelopes and invalid JSON are safely normalized", %{counter: counter} do
    bodies = [
      "not-json raw-secret",
      Jason.encode!(%{}),
      Jason.encode!(%{"choices" => []}),
      Jason.encode!(%{"choices" => [%{"message" => %{}}]}),
      Jason.encode!(%{"choices" => [%{"message" => %{"content" => 42}}]}),
      Jason.encode!(%{"choices" => [%{"message" => %{"content" => "not-json raw-secret"}}]}),
      Jason.encode!(%{"choices" => [%{"message" => %{"content" => "[]"}}]})
    ]

    for body <- bodies do
      req = request(counter, &Plug.Conn.send_resp(&1, 200, body))

      assert {:error, %Error{code: :invalid_provider_response, context: %{}} = error} =
               structured_chat([], opts(req))

      refute inspect(error) =~ "raw-secret"
    end

    assert request_count(counter) == length(bodies)
  end

  test "the fixed response cap accepts exactly 262144 bytes and rejects one byte more", %{
    counter: counter
  } do
    definition = definition("At cap")
    valid_body = provider_body(definition)
    exact_body = valid_body <> String.duplicate(" ", @max_response_bytes - byte_size(valid_body))

    exact_req = request(counter, &Plug.Conn.send_resp(&1, 200, exact_body))
    assert {:ok, ^definition} = structured_chat([], opts(exact_req))

    oversized_req = request(counter, &Plug.Conn.send_resp(&1, 200, exact_body <> " "))

    assert {:error, %Error{code: :invalid_provider_response, context: %{}}} =
             structured_chat([], opts(oversized_req))

    assert request_count(counter) == 2
  end

  test "timeout environment parsing is startup-safe and bounded" do
    for {value, expected} <- [
          {nil, 20_000},
          {"", 20_000},
          {"not-an-integer", 20_000},
          {"-1", 20_000},
          {"0", 20_000},
          {"999", 20_000},
          {"60001", 20_000},
          {"1000", 1_000},
          {"60000", 60_000}
        ] do
      assert runtime_timeout(value) == expected
    end
  end

  defp request(counter, responder) do
    Req.new(
      plug: fn conn ->
        Agent.update(counter, fn state ->
          recorded = %{
            method: conn.method,
            path: conn.request_path,
            body: conn.body_params
          }

          %{state | count: state.count + 1, requests: [recorded | state.requests]}
        end)

        responder.(conn)
      end
    )
  end

  defp structured_chat(messages, opts) do
    format =
      case Keyword.get(opts, :response_kind, :workout_request) do
        :workout_request ->
          {"workout_request", BurpeeTrainer.Coach.WorkoutRequest.json_schema()}

        :workout_layout ->
          {"workout_layout",
           BurpeeTrainer.Coach.WorkoutLayout.json_schema(Keyword.fetch!(opts, :confirmed_request))}
      end

    scope = BurpeeTrainer.Fixtures.scope_fixture()

    opts =
      opts
      |> Keyword.drop([:response_kind, :confirmed_request])
      |> Keyword.put(:response_format, format)
      |> Keyword.put(:ledger, %{scope: scope, purpose: "layout", run_id: Ecto.UUID.generate()})

    case Client.chat(messages, opts) do
      {:ok, %{content: content, tool_calls: []}} when is_map(content) -> {:ok, content}
      {:ok, _} -> {:error, Error.new(:invalid_provider_response)}
      error -> error
    end
  end

  defp opts(req) do
    [
      req: req,
      response_kind: :workout_request,
      config: [
        enabled: true,
        url: "https://provider.test/v1/chat/completions",
        api_key: "test-secret",
        model: "test/model",
        timeout_ms: 12_345
      ]
    ]
  end

  defp request_count(counter), do: Agent.get(counter, & &1.count)
  defp requests(counter), do: Agent.get(counter, &Enum.reverse(&1.requests))

  defp json_response(conn, status, definition) do
    Plug.Conn.send_resp(conn, status, provider_body(definition))
  end

  defp provider_body(definition) do
    Jason.encode!(%{
      "choices" => [%{"message" => %{"content" => Jason.encode!(definition)}}]
    })
  end

  defp definition(name) do
    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "events" => [
        %{
          "kind" => "work",
          "reps" => 10,
          "sec_per_rep" => 12.0,
          "sec_per_burpee" => 12.0
        }
      ],
      "rationale" => "A deterministic provider fixture."
    }
  end

  defp runtime_timeout(value) do
    runtime = Path.expand("../../../config/runtime.exs", __DIR__)

    script = """
    config = Config.Reader.read!(#{inspect(runtime)}, env: :test)
    provider = config |> Keyword.fetch!(:burpee_trainer) |> Keyword.fetch!(:llm_provider)
    IO.write(Integer.to_string(Keyword.fetch!(provider, :timeout_ms)))
    """

    {output, 0} =
      System.cmd(System.find_executable("elixir"), ["-e", script],
        env: [
          {"LLM_PROVIDER_TIMEOUT_MS", value},
          {"LLM_PROVIDER_URL", nil},
          {"LLM_PROVIDER_API_KEY", nil}
        ],
        stderr_to_stdout: true
      )

    output |> String.trim() |> String.to_integer()
  end
end
