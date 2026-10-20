# Bounded training analytics (MCP)

`analyze({"prompt":"How has my six-count pace changed?"})` investigates the signed-in
owner's authoritative completed sessions. Input is **exactly** one nonempty UTF-8
`prompt`, at most 4096 UTF-8 bytes. Unknown keys are refused, including user IDs,
configuration, review modes, deadlines and budgets. Bearer authentication supplies
scope. Coach-disabled owners cannot incur analyst or review calls. This tool is not
available to the in-app Coach.Agent and cannot mutate training data.

Read `burpee://analytics/schema` (MCP resource `analytics-schema`, `text/markdown`)
for the accepted static 14-column `sessions` definition and SQL limits. It contains
no snapshot rows. The existing workout-format resource remains unchanged.

## Reading a result

Successful MCP results have `structuredContent` and the same object encoded in text,
with `isError: false`. All contain `status`, `interpretation`, `answer`, `findings`,
`evidence`, `limitations`, and `trace_id`:

- `answered`: successful SQL evidence and at least one cited evidence ID.
- `needs_clarification`: define the intended metric/comparison before proceeding.
- `insufficient_data`: inadequate comparable history or snapshot coverage too large;
  no biased recent subset is silently substituted.
- `budget_exhausted`: bounded run/call/query/context allowance exhausted; not an answer.

Evidence includes code-generated IDs, analytical intent, SQL, ordered columns and
rows. Trace IDs and citation existence are validated by code. This establishes
**provenance, not semantic proof** that the narrative follows from the numbers.
Provider, executor, reviewer-in-enforce, accounting and trace failures are real MCP
`isError: true` responses, with a safe JSON text `{ "code": "..." }`, not fabricated
empty evidence or insufficient-data success. Error context/provider payloads are
not exposed. `outputSchema` describes the successful output, not these error texts.
`readOnlyHint: true` describes training data only: ledger and private trace writes
still occur.

Actual and planned reps/durations are distinct; missing actuals stay NULL. Canonical
`tags == "warmup"` identifies warmups; credited seconds are
`max(actual duration or 0, 0)` for authoritative non-warmup sessions, otherwise zero.
Dates are captured in the owner's timezone before SQL, including DST. Compare
burpee types and capture methods separately. `reps_per_20_min` is extrapolated
throughput, **not** a prescribed 20-minute PB or comparable-endurance guarantee.
Observational history cannot establish causality. “Improved” may mean volume,
frequency, pace or comparable-session performance; clarify rather than assume.

## Bounds, permissions and review

Each run takes one immutable owner-only snapshot (at most 5000 candidates / 1 MiB).
Helpers receive approved scalar facts, never a production connection, DB path,
credentials, notes, memory or other owners' rows. One SELECT at a time permits
operators/CASE/subqueries and `sum,count,avg,min,max,round,abs,coalesce,nullif`.
Default-deny SQLite authorization rejects writes, metadata, PRAGMA, ATTACH,
extensions, recursive CTEs and unknown functions. The SQL sink is intentional:
`Connection.execute(sql)` follows authorizer/limit setup and rejects extra statements;
regex is not the boundary. No SQL rule is disabled.

A run allows 3 query attempts (including errors), 5 analyst calls, 3 reviewer calls,
8 total reservations, 64 KiB cumulative model context and 48 KiB assembled output.
SQL is at most 4096 bytes; results at most 100 rows, 16 columns, 1024 UTF-8 bytes per
cell and 8 KiB encoded. Overflow refuses instead of truncating an aggregate.
The whole operation has a 45-second watchdog with a 1-second finalization reserve;
analyst/review calls are bounded by 5/3 seconds and remaining allowance. These are
scheduler-sensitive bounds, not hard realtime promises. `receive_timeout` alone is
not a wall bound. The independent metering owner survives cancellation of only the
transport task and attempts bounded ledger completion. A remotely timed-out request
may **still be billed**. Unknown usage/cost stays unknown and the reservation still
counts against shared user/daily/run caps. Ledger finalization failure leaves a
counted inflight row for operator investigation, never a refund or guessed zero.

Configure trusted application settings, not MCP arguments:

```elixir
config :burpee_trainer, :analytics_review, mode: :shadow
```

Modes are `:off`, `:shadow` (default), and `:enforce`. Existing `:llm_provider` and
`:decisions` settings configure analyst and Jev respectively (see runtime.exs and
[MCP setup](mcp-setup.md)); no new provider or independent spending policy is added.
Unconfigured shadow records `review_unavailable` and an unreviewed limitation,
then proceeds without review. Shadow judgments do not redirect analyst behavior.
Enforce unavailable/failed/malformed review returns an error; it never auto-approves.
Jev is experimental reasoning, not a permission boundary or guaranteed improvement.

## Runtime packaging and fail-closed preflight

**Instructions only: no deployment is authorized by this guide.** Non-Linux is
unsupported. Use Python >=3.11 with stdlib SQLite >=3.40 (`setlimit`, `set_authorizer`),
and Linux bubblewrap; no pip, new framework or Exqlite replacement. The tested local
runtime is `/usr/bin/python3` 3.14.8, SQLite 3.53.4 and `/usr/bin/bwrap` 0.13.0.
Pin and record actual image/package versions and hashes in deployment; these local
versions are not an assertion that an arbitrary distribution works.

The release must include both automatically packaged `priv/analytics/` scripts:
`helper_launcher.py` and `sqlite_helper.py`. Guardian resolves the launcher from
`Application.app_dir(:burpee_trainer, "priv/analytics/helper_launcher.py")`, invokes
absolute `/usr/bin/python3 -I`, clears inherited environment and passes trusted BEAM
PID. `/usr/bin/kill` is required for the guardian backstop. There is no configurable
unconfined runner or alternate executable path. Trust files **and ancestors**:
owned by root/service UID, not group/world writable. Install immutable runtime and
helper files; do not place secrets under `/usr`. Service-writeable code is not an
appropriate deployment trust policy even though ownership checks accept service UID.

The accepted launcher fixes `/usr/bin/bwrap --unshare-all --die-with-parent
--new-session --cap-drop ALL`, read-only `/usr`, `/lib -> usr/lib`,
`/lib64 -> usr/lib64`, isolated `/proc`, minimal `/dev`, size-bounded 1 MiB private
`/tmp`, helper-only read-only `/helper.py`, `--clearenv`, and
`/usr/bin/python3 -I /helper.py`. This exact merged-/usr layout must work; do not
silently adapt mounts. No host DB, home, app tree, host /tmp or host network is
mounted. The literal `/tmp` diagnostic refers to a private tmpfs destination, not
insecure host temporary-file creation; keep the rule and evidence, not a suppression.

Required namespaces include user, PID, network, IPC, UTS and mount. Rootless
containers/seccomp/LSM policies must permit them. Readable stable `/proc` ancestry
must identify BEAM or its same-runtime `erl_child_setup`; launcher registers parent
SIGKILL protection. Helper applies and verifies hard=soft rlimits before SQL:
AS 128 MiB, CPU 1 second, CORE 0, NOFILE 32, FSIZE 0. AS is **virtual address space**,
not RSS or a BEAM/application memory cap. Two active helpers maximum; no admission
queue. Guardian captures its 1000 ms whole-helper deadline before startup/input,
submits nonblocking bounded chunks, and kills/reaps on timeout/caller death.
Launcher independently bounds stdout/stderr, kills/reaps bwrap, and parent-death/PID
namespace cleanup kills its worker. Cleanup/scheduling can add latency; closing a
BEAM port is not itself a kill proof.

Before enabling access, run preflight as the **actual service identity**, in the
actual namespace/container/mount policy and release layout, not as privileged root
on the host. Record versions, hashes, ownership and results. A source-build staging
environment with the identical deployed identity/policy must run:

```sh
/usr/bin/bwrap --version
/usr/bin/python3 -I -c 'import sys, sqlite3; print(sys.version); print(sqlite3.sqlite_version)'
python3 -m unittest discover -s test/analytics -p '*_test.py'
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test test/burpee_trainer/analytics/executor_test.exs
```

These maintained suites exercise the actual launcher, denied SQL/tails/functions,
AS/CPU and wall limits, bounded pipes, host-file/network isolation and actual worker
death after cancellation/parent loss. They are necessary policy/limit proof, not a
security certification. A release-only deployment also checks the startup guardian
through its release RPC (substitute the real release executable):

```sh
bin/burpee_trainer rpc 'IO.inspect(BurpeeTrainer.Analytics.HelperGuardian.health())'
```

Require `true`; startup health executes the same sandbox and controls with allowed
and denied queries. Unavailable policy/limits/health means **do not enable analytics**;
`executor_unavailable` is fail closed. If identical-policy maintained proof cannot
run, stop for deployment/security review, never substitute unconfined SQL. Re-run
on runtime/image/policy changes; a developer-machine pass is not deployment proof.

## Sensitive traces and operator access

Question text, interpretation, SQL, compact results/errors, review judgments,
usage and timing are sensitive. No raw snapshot, auth header, provider envelope or
SQL stack trace is logged. Payload limit is 64 KiB; retention is 7 days and at most
20 per owner. Scoped writes/reads prune; expired traces are inaccessible immediately.
The scheduled `Analytics.TraceCleanupJob` deletes expired rows via the existing
Oban coach queue; keep that queue/cron running and investigate failures. Owner
deletion cascades. Retention expiry/pruning can make a previously returned trace ID
unavailable. Trace persistence/overflow failure is explicit, never fake inspectability.

Only explicit trusted local operator access is provided:

```sh
mix burpee_trainer.analytics.trace --user-id ID --trace-id UUID
```

This prints one owner's trace to stdout; protect terminal output/artifacts, restrict
operator access and delete exported copies according to policy. It is not an
unscoped trace list or model-selectable scope. No public trace route or UI exists.

## Evaluation and rollout

See [analytics evaluation](analytics-evaluation.md). Default offline recordings test
protocols only, **not empirical SQL/Jev improvement**. Publicly inspected held-outs
are not secret evaluation data; narrative semantic grading and review opportunity
adjudication remain human work. Live evaluation requires explicit owner opt-in and
positive paid-call budget, never authorized by this implementation. The evaluator
shares the owner-bound `CallBudget` across every arm/case and uses actual durable
reservation counts (including failed/timedout/inflight), not guessed one-call-per-arm
allowances; unresolved accounting halts it. No paid calls were needed for integration.
Final independent security/correctness review and exact-head gates remain required
before production acceptance. No push or deployment is implied.
