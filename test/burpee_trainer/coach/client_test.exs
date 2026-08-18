defmodule BurpeeTrainer.Coach.ClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BurpeeTrainer.Coach.Client
  alias BurpeeTrainer.Workouts.Error

  @max_response_bytes 262_144

  setup do
    counter = start_supervised!({Agent, fn -> %{count: 0, requests: []} end})
    %{counter: counter}
  end

  test "one request uses the fixed security and resource options", %{counter: counter} do
    parent = self()
    definition = definition("One call")

    request =
      request(counter, fn conn -> json_response(conn, 200, definition) end)
      |> Req.Request.prepend_request_steps(
        capture_boundary: fn request ->
          send(parent, {:request_boundary, request})
          request
        end
      )

    boundary_opts =
      request
      |> opts()
      |> Keyword.put(:max_tokens, 99_999)
      |> Keyword.update!(:config, &Keyword.put(&1, :max_tokens, 88_888))

    assert {:ok, ^definition} =
             Client.complete([%{role: "user", content: "steady"}], boundary_opts)

    assert request_count(counter) == 1

    assert_receive {:request_boundary, captured}
    assert captured.method == :post
    assert captured.options.retry == false
    assert captured.options.redirect == false
    assert captured.options.decode_body == false
    assert captured.options.receive_timeout == 12_345
    assert is_function(captured.into, 2)

    [recorded] = requests(counter)
    assert recorded.method == "POST"
    assert recorded.path == "/v1/chat/completions"
    assert recorded.authorization == ["Bearer test-secret"]
    assert recorded.body["model"] == "test/model"
    assert recorded.body["max_tokens"] == 16_384
    assert recorded.body["temperature"] == 0

    assert %{
             "type" => "json_schema",
             "json_schema" => %{
               "name" => "workout_definition",
               "strict" => true,
               "schema" => schema
             }
           } = recorded.body["response_format"]

    assert schema["type"] == "object"
    assert schema["additionalProperties"] == false

    assert schema["required"] == [
             "version",
             "name",
             "burpee_type",
             "target_duration_sec",
             "target_reps",
             "pacing_style",
             "rationale",
             "events"
           ]

    assert schema["properties"]["version"] == %{"type" => "integer", "enum" => [1]}
    assert schema["properties"]["burpee_type"]["enum"] == ["six_count", "navy_seal"]
    assert schema["properties"]["pacing_style"]["enum"] == ["even", "unbroken"]

    assert %{"type" => "array", "minItems" => 1, "items" => %{"anyOf" => events}} =
             schema["properties"]["events"]

    assert Enum.map(events, & &1["required"]) == [
             ["kind", "reps", "sec_per_rep", "sec_per_burpee"],
             ["kind", "duration_sec"]
           ]

    assert Enum.all?(events, &(&1["additionalProperties"] == false))
    assert Enum.at(events, 0)["description"] =~ "Only work events contribute repetitions"
    assert Enum.at(events, 1)["description"] =~ "Rest events contribute zero repetitions"
    assert recorded.body["messages"] == [%{"role" => "user", "content" => "steady"}]
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
                 Client.complete([%{role: "user", content: "private"}], opts(req))
      end)

    assert log =~ "llm_provider_response_rejected"
    assert log =~ "stage=envelope"
    assert log =~ "finish_reason=length"
    assert log =~ "content_type=nil"
    refute log =~ "private"
  end

  test "disabled configuration returns before credentials or request construction", %{
    counter: counter
  } do
    req = request(counter, fn conn -> json_response(conn, 200, definition("unused")) end)

    assert {:error, %Error{code: :provider_unavailable, context: %{}}} =
             Client.complete([],
               req: req,
               config: [enabled: false, url: nil, api_key: nil, model: nil]
             )

    assert request_count(counter) == 0
  end

  test "only literal true enables the provider and malformed values have safe empty context", %{
    counter: counter
  } do
    req = request(counter, fn conn -> json_response(conn, 200, definition("unused")) end)

    for enabled <- [nil, false, 1, 0, "true", %{}, []] do
      assert {:error, %Error{code: :provider_unavailable, context: %{}}} =
               Client.complete([],
                 req: req,
                 config: [
                   enabled: enabled,
                   url: "https://provider.test/v1",
                   api_key: "secret",
                   model: "test/model"
                 ]
               )
    end

    assert request_count(counter) == 0
  end

  test "enabled configuration with missing credentials makes no request", %{counter: counter} do
    req = request(counter, fn conn -> json_response(conn, 200, definition("unused")) end)

    for config <- [
          [enabled: true, url: "https://provider.test/v1", api_key: "secret"],
          [enabled: true, url: "https://provider.test/v1", model: "test/model"],
          [enabled: true, api_key: "secret", model: "test/model"],
          [enabled: true, url: " ", api_key: "secret", model: "test/model"]
        ] do
      assert {:error, %Error{code: :provider_unavailable}} =
               Client.complete([], req: req, config: config)
    end

    assert request_count(counter) == 0
  end

  test "timeouts and transport failures are safely normalized without raw reasons", %{
    counter: counter
  } do
    timeout_req = request(counter, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Error{code: :provider_timeout, context: %{}}} =
             Client.complete([], opts(timeout_req))

    transport_req = request(counter, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Error{code: :provider_unavailable, context: %{}}} =
             Client.complete([], opts(transport_req))

    assert request_count(counter) == 2
  end

  test "unexpected Req errors are normalized without leaking their message" do
    req = %{
      Req.new()
      | adapter: fn request -> {request, RuntimeError.exception("raw-secret-error")} end
    }

    assert {:error, %Error{code: :provider_unavailable, context: %{}} = error} =
             Client.complete([], opts(req))

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
               Client.complete([], opts(req))

      refute inspect(error) =~ "raw-secret-provider-body"
    end

    assert request_count(counter) == length(statuses)
  end

  test "an inherited follow_redirects option cannot override redirect rejection", %{
    counter: counter
  } do
    definition = definition("must not be reached")

    req =
      request(counter, fn conn ->
        case conn.request_path do
          "/v1/chat/completions" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/redirected")
            |> Plug.Conn.send_resp(302, "redirect body")

          "/redirected" ->
            json_response(conn, 200, definition)
        end
      end)
      |> Req.merge(follow_redirects: true)

    assert {:error, %Error{code: :provider_unavailable, context: %{status: 302}}} =
             Client.complete([], opts(req))

    assert request_count(counter) == 1
  end

  test "inherited http_errors cannot raise or leak a non-200 body" do
    test_pid = self()

    req =
      Req.new(
        http_errors: :raise,
        adapter: fn request ->
          send(test_pid, :provider_called)
          {request, %Req.Response{status: 503, body: "raw-secret-provider-body"}}
        end
      )

    assert {:error, %Error{code: :provider_unavailable, context: %{status: 503}} = error} =
             Client.complete([], opts(req))

    assert_receive :provider_called
    refute inspect(error) =~ "raw-secret-provider-body"
  end

  test "the final body cap applies before every non-200 status" do
    oversized_body = String.duplicate("raw-secret", div(@max_response_bytes, 10) + 1)

    for status <- [302, 429, 503] do
      req = %{
        Req.new()
        | adapter: fn request ->
            {request, %Req.Response{status: status, body: oversized_body}}
          end
      }

      assert {:error, %Error{code: :invalid_provider_response, context: %{}} = error} =
               Client.complete([], opts(req))

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
               Client.complete([], opts(req))
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
               Client.complete([], opts(req))

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
    assert {:ok, ^definition} = Client.complete([], opts(exact_req))

    oversized_req = request(counter, &Plug.Conn.send_resp(&1, 200, exact_body <> " "))

    assert {:error, %Error{code: :invalid_provider_response, context: %{}}} =
             Client.complete([], opts(oversized_req))

    assert request_count(counter) == 2
  end

  test "the final body cap rejects an adapter that ignores into" do
    valid_body = provider_body(definition("adapter ignored into"))

    oversized_body =
      valid_body <> String.duplicate(" ", @max_response_bytes + 1 - byte_size(valid_body))

    req = %{
      Req.new()
      | adapter: fn request ->
          {request, %Req.Response{status: 200, body: oversized_body}}
        end
    }

    assert {:error, %Error{code: :invalid_provider_response, context: %{}}} =
             Client.complete([], opts(req))
  end

  test "the response cap also rejects a chunked body", %{counter: counter} do
    chunk = String.duplicate("x", div(@max_response_bytes, 2) + 1)

    req =
      request(counter, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)

    assert {:error, %Error{code: :invalid_provider_response, context: %{}}} =
             Client.complete([], opts(req))

    assert request_count(counter) == 1
  end

  test "custom adapter streaming halts when under-limit chunks aggregate to cap plus one" do
    first_chunk = String.duplicate("first-secret", 11_916) |> binary_part(0, 131_072)
    second_chunk = String.duplicate("second-secret", 11_916) |> binary_part(0, 131_073)
    req = streaming_adapter(self(), [first_chunk, second_chunk])

    assert {:error, %Error{code: :invalid_provider_response, context: %{}} = error} =
             Client.complete([], opts(req))

    assert_receive {:stream_outcomes, [:cont, :halt], {:error, :response_too_large}}
    refute inspect(error) =~ "first-secret"
    refute inspect(error) =~ "second-secret"
  end

  test "custom adapter streaming accepts an aggregate body at the exact cap" do
    definition = definition("exact streamed cap")
    valid_body = provider_body(definition)
    exact_body = valid_body <> String.duplicate(" ", @max_response_bytes - byte_size(valid_body))
    <<first_chunk::binary-size(131_072), second_chunk::binary>> = exact_body
    req = streaming_adapter(self(), [first_chunk, second_chunk])

    assert {:ok, ^definition} = Client.complete([], opts(req))
    assert_receive {:stream_outcomes, [:cont, :cont], body}
    assert byte_size(body) == @max_response_bytes
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

  defp streaming_adapter(test_pid, chunks) do
    %{
      Req.new()
      | adapter: fn request ->
          {request, response, outcomes} =
            Enum.reduce_while(
              chunks,
              {request, %Req.Response{status: 200, body: ""}, []},
              fn chunk, {request, response, outcomes} ->
                case request.into.({:data, chunk}, {request, response}) do
                  {:cont, {request, response}} ->
                    {:cont, {request, response, [:cont | outcomes]}}

                  {:halt, {request, response}} ->
                    {:halt, {request, response, [:halt | outcomes]}}
                end
              end
            )

          send(test_pid, {:stream_outcomes, Enum.reverse(outcomes), response.body})
          {request, response}
        end
    }
  end

  defp request(counter, responder) do
    Req.new(
      plug: fn conn ->
        Agent.update(counter, fn state ->
          recorded = %{
            method: conn.method,
            path: conn.request_path,
            authorization: Plug.Conn.get_req_header(conn, "authorization"),
            body: conn.body_params
          }

          %{state | count: state.count + 1, requests: [recorded | state.requests]}
        end)

        responder.(conn)
      end
    )
  end

  defp opts(req) do
    [
      req: req,
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
