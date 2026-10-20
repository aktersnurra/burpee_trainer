defmodule BurpeeTrainer.Coach.ClientDeadlineTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Client, LlmCall}

  @config [enabled: true, url: "http://localhost/recorded", api_key: "local", model: "recorded"]

  test "absolute deadline cancels a blocked adapter and retains unknown billing" do
    scope = scope_fixture()
    owner = self()

    req =
      Req.new(
        adapter: fn request ->
          send(owner, {:transport, self()})

          receive do
            :never -> {request, Req.Response.new(status: 200)}
          end
        end
      )

    started = System.monotonic_time(:millisecond)

    assert {:error, %{code: :provider_timeout}} =
             Client.chat([],
               config: @config,
               req: req,
               deadline_ms: started + 150,
               ledger: %{scope: scope, purpose: "analytics", run_id: Ecto.UUID.generate()}
             )

    assert System.monotonic_time(:millisecond) - started < 650
    assert_received {:transport, pid}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert [%{outcome: "timeout", cost_usd: nil, prompt_tokens: nil}] = Repo.all(LlmCall)
  end

  test "expired deadline admits no reservation or transport" do
    scope = scope_fixture()

    assert {:error, %{code: :provider_timeout}} =
             Client.chat([],
               config: @config,
               deadline_ms: System.monotonic_time(:millisecond) - 1,
               ledger: %{scope: scope, purpose: "analytics", run_id: Ecto.UUID.generate()}
             )

    assert Repo.aggregate(LlmCall, :count) == 0
  end

  test "real stalled TLS handshake obeys the absolute deadline and releases its socket" do
    owner = self()
    {listener, port} = listener()

    start_supervised!({Task,
     fn ->
       {:ok, socket} = :gen_tcp.accept(listener)
       send(owner, :tls_accepted)
       # Read ClientHello, deliberately never send ServerHello.
       {:ok, _hello} = :gen_tcp.recv(socket, 0, 2000)
       drain_tls(socket)
       send(owner, :tls_closed)
     end})

    started = System.monotonic_time(:millisecond)

    assert {:error, %{code: :provider_timeout}} =
             Client.chat(
               [],
               deadline_opts(scope_fixture(), "https://127.0.0.1:#{port}/", started + 200)
             )

    assert System.monotonic_time(:millisecond) - started < 700
    assert_receive :tls_accepted
    assert_receive :tls_closed, 1000
    assert [%{outcome: "timeout", cost_usd: nil}] = Repo.all(LlmCall)
  end

  test "real slow chunks within receive timeout still exceed absolute deadline; next request works" do
    owner = self()
    {listener, port} = listener()

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
         :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
         send(owner, :stream_started)
         stream_until_closed(socket, owner)
         {:ok, next} = :gen_tcp.accept(listener)
         {:ok, _} = :gen_tcp.recv(next, 0, 2000)
         body = Jason.encode!(%{"choices" => [%{"message" => %{"content" => "ok"}}]})

         :ok =
           :gen_tcp.send(
             next,
             "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
               body
           )

         :gen_tcp.close(next)
       end}
    )

    scope = scope_fixture()
    started = System.monotonic_time(:millisecond)
    url = "http://127.0.0.1:#{port}/"

    assert {:error, %{code: :provider_timeout}} =
             Client.chat([], deadline_opts(scope, url, started + 250))

    assert System.monotonic_time(:millisecond) - started < 750
    assert_receive :stream_started
    assert_receive {:chunks_before_close, n}, 1000
    assert n >= 3

    assert {:ok, %{content: "ok"}} =
             Client.chat(
               [],
               deadline_opts(scope, url, System.monotonic_time(:millisecond) + 1000)
             )

    assert Enum.sort(Repo.all(from(c in LlmCall, select: c.outcome))) == ["ok", "timeout"]
  end

  test "caller death cancels blocked transport and finishes one counted reservation" do
    scope = scope_fixture()
    owner = self()

    req =
      Req.new(
        adapter: fn request ->
          send(owner, {:blocked, self()})

          receive do
            :never -> {request, Req.Response.new(status: 200)}
          end
        end
      )

    caller =
      start_supervised!(
        {Task,
         fn ->
           Client.chat(
             [],
             deadline_opts(scope, @config[:url], System.monotonic_time(:millisecond) + 1000) ++
               [req: req]
           )
         end}
      )

    assert_receive {:blocked, transport}
    monitor = Process.monitor(transport)
    # Monitor the surviving meter before cancellation so its termination proves finish completed.
    [{_, coordinator, _, _}] =
      DynamicSupervisor.which_children(BurpeeTrainer.Coach.Client.Deadline.Supervisor)

    meter_ref = Process.monitor(coordinator)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^transport, _}
    assert_receive {:DOWN, ^meter_ref, :process, ^coordinator, :normal}
    assert [%{outcome: "cancelled", cost_usd: nil}] = Repo.all(LlmCall)
  end

  test "real saturated single-connection pool times out, releases checkout and is reusable" do
    owner = self()
    {listener, port} = listener()
    url = "http://127.0.0.1:#{port}/"

    server =
      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
           send(owner, {:holding_connection, self()})

           receive do
             :release -> :ok
           end

           :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
           # Reuse the same actual connection after the timed-out checkout.
           {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
           :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
           :gen_tcp.close(socket)
         end},
        id: :saturated_server
      )

    req =
      Req.new(
        finch: [size: 1, count: 1],
        adapter: fn request ->
          pool_options =
            Keyword.drop(request.options.finch, [
              :pool_timeout,
              :receive_timeout,
              :request_timeout
            ])

          send(owner, {:pool_config, self(), pool_options})

          receive do
            :pool_saturated -> Req.Finch.run(request)
          end
        end
      )

    scope = scope_fixture()

    caller =
      start_supervised!(
        {Task,
         fn ->
           result =
             Client.chat(
               [],
               deadline_opts(scope, url, System.monotonic_time(:millisecond) + 350) ++ [req: req]
             )

           send(owner, {:saturated_result, result})
         end},
        id: :pool_caller
      )

    assert_receive {:pool_config, transport, pool_options}
    name = Req.Finch.pool_name(pool_options)
    start_supervised!({Finch, name: name, pools: %{default: pool_options}})

    holder =
      start_supervised!(
        {Task,
         fn ->
           result = Finch.request(Finch.build(:get, url), name, receive_timeout: 2000)
           send(owner, {:holder_finished, result})
         end},
        id: :holder
      )

    assert_receive {:holding_connection, ^server}
    send(transport, :pool_saturated)
    caller_ref = Process.monitor(caller)
    assert_receive {:saturated_result, {:error, %{code: :provider_timeout}}}, 850
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert [%{outcome: "timeout", cost_usd: nil}] = Repo.all(LlmCall)
    holder_ref = Process.monitor(holder)
    send(server, :release)
    assert_receive {:holder_finished, {:ok, _}}
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}

    assert {:ok, %{status: 200}} =
             Finch.request(Finch.build(:get, url), name, pool_timeout: 500, receive_timeout: 500)
  end

  test "absolute watchdog covers blocked recorded response processing, not only transport" do
    owner = self()

    req =
      BurpeeTrainer.AnalyticsProviderPlug.request([%{"recorded" => true}])
      |> Req.Request.prepend_response_steps(
        parse_recording: fn {request, response} ->
          send(owner, {:parsing_recording, self()})

          receive do
            :never -> {request, response}
          end
        end
      )

    scope = scope_fixture()
    started = System.monotonic_time(:millisecond)

    assert {:error, %{code: :provider_timeout}} =
             Client.chat([], deadline_opts(scope, @config[:url], started + 150) ++ [req: req])

    assert System.monotonic_time(:millisecond) - started < 650
    assert_received {:parsing_recording, pid}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert [%{outcome: "timeout", cost_usd: nil}] = Repo.all(LlmCall)
  end

  test "bounded ledger finish failure is explicit and leaves one counted durable reservation" do
    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER analytics_meter_failure BEFORE UPDATE ON llm_calls BEGIN SELECT RAISE(ABORT, 'meter finish failed'); END",
      []
    )

    scope = scope_fixture()
    run_id = Ecto.UUID.generate()
    req = BurpeeTrainer.AnalyticsProviderPlug.request([%{"recorded" => true}])

    opts = [
      config: @config,
      req: req,
      deadline_ms: System.monotonic_time(:millisecond) + 500,
      ledger: %{scope: scope, purpose: "analytics", run_id: run_id}
    ]

    assert {:error, %{code: :ledger_finalization_failed}} = Client.chat([], opts)
    assert [%{outcome: "inflight", cost_usd: nil}] = Repo.all(LlmCall)

    assert {:ok, %{reservations: 1, inflight: 1}} =
             BurpeeTrainer.Coach.Ledger.reservation_count(scope, run_id)
  end

  test "effective Finch socket timeout tightens below every absolute allowance" do
    owner = self()
    scope = scope_fixture()
    allowances = [200, 400, 800, 1600, 6400, 25_600, 60_000]

    for allowance <- allowances do
      req =
        BurpeeTrainer.AnalyticsProviderPlug.request([%{"recorded" => true}])
        |> Req.Request.prepend_request_steps(
          effective_connection: fn request ->
            pool_options =
              Keyword.drop(request.options.finch, [
                :pool_timeout,
                :receive_timeout,
                :request_timeout
              ])

            {:ok, effective} = Finch.cast_pool_opts(pool_options)

            send(
              owner,
              {:effective_connection, effective.conn_opts[:transport_opts][:timeout],
               request.options.finch}
            )

            request
          end
        )

      config = Keyword.put(@config, :timeout_ms, 60_000)

      assert {:ok, _} =
               Client.chat([],
                 config: config,
                 req: req,
                 deadline_ms: System.monotonic_time(:millisecond) + allowance,
                 ledger: %{scope: scope, purpose: "analytics", run_id: Ecto.UUID.generate()}
               )

      assert_receive {:effective_connection, timeout, finch}
      assert timeout > 0 and timeout <= allowance
      assert timeout <= finch[:receive_timeout]
      assert timeout in Enum.map(0..15, &Integer.pow(2, &1))
      assert finch[:pool_timeout] <= allowance
      assert finch[:request_timeout] <= allowance
    end
  end

  test "varied absolute deadlines keep surviving local Finch instances bounded" do
    {listener, port} = listener()
    allowances = Enum.to_list(1150..1161) ++ Enum.to_list(3300..3311)

    start_supervised!(
      {Task,
       fn ->
         for _ <- allowances do
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
           body = Jason.encode!(%{"choices" => [%{"message" => %{"content" => "local"}}]})

           :ok =
             :gen_tcp.send(
               socket,
               "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
                 body
             )

           :gen_tcp.close(socket)
         end
       end}
    )

    scope = scope_fixture()
    before_instances = finch_instances()

    for allowance <- allowances do
      assert {:ok, %{content: "local"}} =
               Client.chat(
                 [],
                 deadline_opts(
                   scope,
                   "http://127.0.0.1:#{port}/",
                   System.monotonic_time(:millisecond) + allowance
                 )
               )
    end

    new_instances = MapSet.difference(finch_instances(), before_instances)
    assert MapSet.size(new_instances) <= 2
    assert Repo.aggregate(LlmCall, :count) == 24
  end

  defp finch_instances do
    Req.FinchSupervisor
    |> DynamicSupervisor.which_children()
    |> MapSet.new(fn {_, pid, _, _} -> pid end)
  end

  defp drain_tls(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, _alert} -> drain_tls(socket)
      {:error, :closed} -> :ok
      other -> flunk("TLS socket did not close: #{inspect(other)}")
    end
  end

  defp listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp stream_until_closed(socket, owner, count \\ 0) do
    receive do
    after
      30 ->
        case :gen_tcp.send(socket, "1\r\n \r\n") do
          :ok ->
            stream_until_closed(socket, owner, count + 1)

          {:error, _} ->
            :gen_tcp.close(socket)
            send(owner, {:chunks_before_close, count})
        end
    end
  end

  defp deadline_opts(scope, url, deadline),
    do: [
      config: Keyword.put(@config, :url, url),
      deadline_ms: deadline,
      ledger: %{scope: scope, purpose: "analytics", run_id: Ecto.UUID.generate()}
    ]
end
