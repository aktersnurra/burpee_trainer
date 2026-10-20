defmodule BurpeeTrainer.Analytics.TraceTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Analytics.{Trace, TraceCleanupJob, TraceRecord}

  test "owned, unexpired bounded traces retain only twenty and cascade with owner" do
    scope = scope_fixture()
    other = scope_fixture()
    now = ~U[2026-10-20 00:00:00.000000Z]
    id = Ecto.UUID.generate()
    assert :ok = Trace.store(scope, id, %{"prompt" => "private"}, now: now)
    assert {:ok, %{"prompt" => "private"}} = Trace.fetch(scope, id, now: now)
    assert {:error, :not_found} = Trace.fetch(other, id, now: now)

    assert {:error, :trace_too_large} =
             Trace.store(scope, Ecto.UUID.generate(), %{"x" => String.duplicate("a", 65_536)},
               now: now
             )

    for n <- 1..20 do
      assert :ok =
               Trace.store(scope, Ecto.UUID.generate(), %{"n" => n},
                 now: DateTime.add(now, n, :second)
               )
    end

    assert Repo.aggregate(TraceRecord, :count) == 20
    assert {:error, :not_found} = Trace.fetch(scope, id, now: now)
    assert :ok = TraceCleanupJob.perform(%Oban.Job{args: %{}})
    Repo.delete!(scope.user)
    assert Repo.aggregate(TraceRecord, :count) == 0
  end

  test "expiry is inaccessible immediately and pruned on scoped reads" do
    scope = scope_fixture()
    now = DateTime.utc_now()
    id = Ecto.UUID.generate()
    assert :ok = Trace.store(scope, id, %{}, now: DateTime.add(now, -8, :day))
    assert {:error, :not_found} = Trace.fetch(scope, id, now: now)
    assert Repo.aggregate(TraceRecord, :count) == 0
  end

  test "timeout with a persisted trace returns inspectable exhaustion, absence never invents an id" do
    scope = scope_fixture()
    id = Ecto.UUID.generate()

    assert :ok =
             Trace.store(scope, id, %{
               "interpretation" => "count",
               "evidence" => [],
               "final" => %{}
             })

    deadline = System.monotonic_time(:millisecond) + 1000

    assert {:ok, %{"status" => "budget_exhausted", "trace_id" => ^id}} =
             Trace.timeout(scope, id, deadline)

    assert {:ok, %{"final" => %{"status" => "budget_exhausted"}}} = Trace.fetch(scope, id)
    assert {:error, %{code: :run_timeout}} = Trace.timeout(scope_fixture(), id, deadline)
    assert {:error, %{code: :run_timeout}} = Trace.timeout(scope, Ecto.UUID.generate(), deadline)
  end
end
