# Bounded training analytics agent

Date: 2026-10-20. Status: implementation contract; capability spike complete, not a shipped feature.
Base: `f8eb62c7`. Scope: authenticated MCP `analyze({prompt})`, reusable Elixir context, independent experimental Jev review, offline comparison corpus. No UI, autonomous writes, kcal, new agent framework, or live benchmark claims.

## Capability decision and evidence

The owner approved a separate OS-isolated SQLite helper after the planner escalated the pinned dependency's gaps. Keep the Elixir controller and existing `Coach.Client`/ledger. Do not patch Exqlite or installed dependencies.

Pinned `mix.lock` Exqlite 0.42.0 is insufficient as the untrusted SQL boundary:

- `deps/exqlite/c_src/sqlite3_nif.c:1854` authorizer only checks an operation-code deny array; ignores function name/table arguments. Denying `:function` denies useful SUM/COUNT along with unsafe functions. Named policies are not supported.
- `:819` passes NULL for `sqlite3_prepare_v3`'s tail. `prepare("SELECT 1; ATTACH ...")` succeeds and executes only SELECT, rather than rejecting multiple statements.
- `lib/exqlite/sqlite3.ex` has no public `sqlite3_limit` or per-connection allocator cap. `shrink_memory` is not a cap. PRAGMA hard_heap_limit is SQLite-global, unsuitable for the application's shared NIF runtime.
- `c_src/sqlite3_nif.c:499, 2214` progress handler observes cancellation; cancel also interrupts and wakes busy waits. Probe confirms cancellation of an active recursive aggregate. This does not preempt arbitrary allocation/function execution or prove a hard deadline. Killing an Erlang caller is not cancellation of a dirty NIF.

Executable planning probes and full outputs live under `.docs/analytics-agent/`: `exqlite_capability_test.exs`, `sandbox_capability_test.py`, `exqlite-capability.log`, `sandbox-capability.log`. Existing focused MCP baseline: 57 passed. Probes establish feasibility, not production security certification. Task 1 must promote the relevant assertions into maintained tests and test its actual launcher/protocol.

## Approved runtime boundary

Use a small Python standard-library helper (`priv/analytics/sqlite_helper.py`), Linux bubblewrap, and Python >=3.11 / SQLite >=3.40 with `Connection.setlimit` and `set_authorizer`. No pip packages, SQL parser dependency, new NIF, shell interpolation, network client, or production database file. The installed proof used Python 3.14.8, SQLite 3.53.4. Record and check supported runtime versions at startup; pin OS image/package versions in deployment rather than claiming the Python SQLite engine is Exqlite's engine.

Each query starts a fresh helper from the *same immutable bounded snapshot*. It builds only `sessions` in `:memory:` using fixed DDL and bound inserts, commits, sets limits, then installs a default-deny authorizer before preparing model SQL. Helpers never receive credentials, user IDs, DB paths, or raw application/provider structs. A one-query process avoids connection reuse/cancel races. SQL errors cannot poison the next query.

Launch only an absolute configured executable and fixed argv, through `Port.open({:spawn_executable, ...})`, not a shell. The sandbox argv uses `--unshare-all --die-with-parent --new-session --cap-drop ALL`, read-only `/usr`, distribution-specific read-only library mounts/symlinks, isolated `/proc`, minimal `/dev`, a size-bounded private `/tmp`, only the helper script mounted read-only at `/helper.py`, `--clearenv`, and `/usr/bin/python3 -I /helper.py`. No home, application tree, database directory, secrets directory, host `/tmp`, host network, or inherited non-protocol descriptors. Validate executable/helper ownership and non-world-writability. `/usr` is a runtime mount: deployments must not place secrets there. Require Linux unprivileged namespaces and bubblewrap; never use `--not-a-security-boundary` or an unconfined fallback. Rootless container policies must explicitly permit the required namespaces.

Before accepting input, helper sets hard=soft `RLIMIT_AS=128 MiB`, `RLIMIT_CPU=1 second`, `RLIMIT_CORE=0`, `RLIMIT_NOFILE=32`, `RLIMIT_FSIZE=0`; verifies them. Disable temp files (`temp_store=MEMORY`), extension loading, and trusted schema before untrusted SQL. No model-controlled setup PRAGMA. Read a four-byte big-endian input length, reject >2 MiB, then read exactly that many JSON bytes; premature EOF is invalid. Do not wait for stdin EOF (BEAM ports cannot half-close stdin). The trusted guardian is the sole writer and sends exactly one frame; helper exits after its one response. Runtime code is trusted, SQL/data are not. RLIMIT_AS bounds virtual allocation for the helper (not BEAM RSS); it is not an application-wide memory guarantee. SQL is the threat model, not arbitrary Python code execution or a hostile kernel.

An Elixir guardian owns the port independently of the request process, monitors caller death, and enforces a 1,000 ms *whole-helper* deadline including startup/input/prepare/fetch. On timeout/caller death, explicitly SIGKILL the trusted bwrap OS PID, await exit, and close/drain the port. `Port.close` alone is not a kill proof. `--die-with-parent`/PID namespace kills the worker when bwrap/guardian dies; no untrusted child can spawn through allowed SQL. Test actual child cleanup via host PID/status monitoring, including caller death. No production execution until hard kill/reap is proved. Max two active helpers application-wide; admission returns `executor_busy`, no unbounded waiting queue.

Startup health check runs the same sandbox with denied ATTACH/function/tail and rlimit probes; absent/failed controls disable analytics with `executor_unavailable`. Do not silently weaken the contract on another OS. A deployment must run this health check as the service identity; developer-machine success does not prove deployment feasibility.

### SQL enforcement

Use Python `Connection.execute(sql)` (never `executescript`). It prepares one statement and rejects non-comment trailing statements, including ones hidden by quoted semicolons/comments; NUL rejected explicitly. Empty/no-result statements are errors. Retain legal trailing comments. Verify this on supported CPython releases in regression tests, not regex splitting. Default deny every authorizer action except SELECT, READ of `main.sessions` approved columns (including SQLite's empty-column COUNT case), and the following lowercase named functions: `sum,count,avg,min,max,round,abs,coalesce,nullif`. Match function name from SQLITE_FUNCTION arg2, not arg1. No RECURSIVE, transaction, PRAGMA, ATTACH/DETACH, schema writes, temp objects, metadata tables, virtual/table-valued functions, extension loading, file functions, randomblob/zeroblob/printf, date/time functions, or unknown future action. Operators/CASE and ordinary SELECT subqueries/joins are available subject to bounds. No regex-only security or Jev permission override.

Set SQLite limits to SQL_LENGTH=4,096; LENGTH=65,536; COLUMN=16; EXPR_DEPTH=64; COMPOUND_SELECT=8; VDBE_OP=25,000; ATTACHED=0; VARIABLE_NUMBER=0; WORKER_THREADS=0. Verify effective values, failing closed if required controls unavailable. Data insertion happens before VARIABLE_NUMBER=0 and restrictive authorizer. Progress callback every 100 VM operations checks monotonic deadline; this is a fast cooperative stop, with OS kill as hard backstop. Fetch incrementally; never fetchall. Return at most 100 rows, 16 columns, 1,024 UTF-8 bytes per string/cell, 8 KiB encoded result. Exceeding a limit returns `result_too_large`, never a misleading partial aggregate or silently truncated evidence. Reject non-finite numeric output and duplicate column names; use array rows with explicit ordered columns. Bound stdout/stderr independently and kill on overflow; never log helper stderr verbatim.

Protocol v1: one length-prefixed bounded JSON object via stdin (no request EOF requirement): `{version:1, rows:[[...]], sql:"..."}`; column order is compiled into helper and `Schema.columns/0`, not model input. Response one JSON object then EOF: `{version:1, ok:true, columns:[...], rows:[[...]]}` or `{version:1, ok:false, code:"sql_denied|sql_error|result_too_large|query_timeout|invalid_input"}`. Elixir validates version, types, bounds, exit status, absence of trailing bytes; helper messages do not contain raw exception paths. Elixir adds evidence IDs/timing. Whole stdin <=2 MiB plus four-byte frame header, stdout <=8 KiB, stderr <=1 KiB. Any malformed output, crash, signal, sandbox failure, timeout, or unavailable resource control is an explicit error, not empty successful evidence.

## Snapshot and metric contract

`Analytics.Snapshot.build(%Scope{}, now: DateTime.t()) -> {:ok, %Snapshot{rows, as_of, timezone, schema_version:1}} | {:error, atom}`. Load in one read transaction from `WorkoutSession` with `user_id == scope.user.id`, completed_at <= fixed now, state completed, then require `AuthoritativeSession.authoritative?/1`. No model-supplied filters/user IDs. Read at most 5,001 candidates; >5,000 refuses with `snapshot_too_large`, never silently picks a biased recent subset. Strict projection excludes raw notes, memory, cadence, program/video JSON, workout names, free-form tags, credentials, and all other tables. Source validity may inspect snapshots in trusted Elixir but only the approved scalar projection crosses the boundary. Max encoded snapshot 1 MiB, max helper envelope 2 MiB; all queries reuse exactly those rows. Invalid timezone returns `invalid_timezone`, no UTC fallback.

One table `sessions`, columns in this exact order (SQLite types):

| Column | Type / definition |
| --- | --- |
| session_id | INTEGER, owned session id, evidence link only |
| completed_at | TEXT UTC ISO8601 |
| local_date | TEXT YYYY-MM-DD, `UserTime.local_date/2` using captured owner timezone |
| source_kind | TEXT plan/video/manual |
| burpee_type | TEXT six_count/navy_seal |
| capture_mode | TEXT tracked/timed/logged |
| reps_actual | INTEGER nullable, `burpee_count_actual` |
| reps_planned | INTEGER nullable, `burpee_count_planned` |
| duration_sec_actual | INTEGER nullable |
| duration_sec_planned | INTEGER nullable |
| credited_seconds | INTEGER, `History.credited_seconds/1`: max(actual duration or 0, 0) for authoritative non-warmup sessions; 0 otherwise |
| warmup | INTEGER 0/1; canonical `tags == "warmup"` convention, not generic substring matching |
| pace_sec | REAL nullable; actual duration / actual reps only if both positive |
| reps_per_20_min | INTEGER nullable; `round(actual reps / actual duration * 1200)` matching `Stats.Series.progress/1` |

Keep malformed/missing actuals as NULL, never substitute planned work into actual pace. Completed sessions may count credited minutes differently from measured duration; document `History.credited_seconds/1` precisely in schema resource. Include warmups explicitly; prompts default to non-warmup comparisons and separate burpee types/capture methods. Normalized throughput is extrapolation, not a prescribed 20-minute PB or proof of comparable endurance. PB eligibility remains `AuthoritativeSession.prescribed_plan_pb_eligible?/1`; this schema does not expose sufficient fields to certify it. No causal inference from observational data. No universal meaning of “improved”: clarify whether volume, frequency, pace or comparable-session performance unless user supplied a definition. Local dates are computed before SQL, preserving DST behavior without SQLite timezone assumptions.

## Elixir interfaces and budgets

Modules under `BurpeeTrainer.Analytics`:

- `Schema.columns/0`, `Schema.text/0`, `Schema.version/0`; resource is `burpee://analytics/schema`, static and non-user-specific.
- `Executor.query(%Snapshot{}, sql, timeout_ms: <=1_000) -> {:ok, %{columns:[string], rows:[[scalar]], duration_ms:integer}} | {:error, code}`. Helper guardian/launcher implements the OS boundary above. Caller cannot supply a looser cap.
- `Analytics.analyze(%Scope{}, prompt, opts \\ []) -> {:ok, output_map} | {:error, %Workouts.Error{}}`. Trusted options permit deterministic clock/recorded Req transport in tests; MCP cannot choose config, review mode, or limits.
- `Trace.fetch(%Scope{}, trace_id) -> {:ok, payload} | {:error, :not_found}`. No unscoped public lookup. `Output.validate(map, evidence_ids)` performs strict validation and existence checks, not semantic grading.

Limits are shared constants, not independently drifting prompt text: prompt 4,096 UTF-8 bytes, analytical intent 512 bytes, SQL 4,096 bytes, snapshot 5,000 rows / 1 MiB, queries 3 attempts including denied/error queries, analyst model calls 5, review model calls 3, combined ledger reservations 8, run wall deadline 45,000 ms, helper wall 1,000 ms, analyst HTTP timeout <=5,000 ms, review <=3,000 ms, each provider body <=existing Client 262,144 bytes. Cumulative accepted model text/context 64 KiB, per assembled final output 48 KiB (model narrative <=8 KiB). No next operation if remaining deadline cannot fit its timeout; exhaustion produces budget_exhausted. Pass a tightened config timeout to existing Client (its lower bound is 1,000 ms), never kill an inflight metered request as ordinary budget control. Existing Client max output tokens stays unchanged; oversized content is rejected before it enters trace/context.

Reuse `Client.chat/2` for analyst, `Client.decide/3` for Jev; purposes `analytics` and `analytics_review`, same generated UUID run_id and `budget: [run_cap: 8]`. Ledger's non-automated purposes already use user bucket and share global daily cost policy; test this explicitly. Every request passes trusted scope. Disabled coach/provider makes zero paid calls; errors return provider_unavailable/llm_budget_exhausted consistently. Existing Client performs actual billing/usage finish even on invalid output. Do not route through `Coach.Agent` or expose its mutation tools.

## Bounded loop and typed output

Analyst response is a strict tagged JSON object with action `query`, `final`, or `clarify`. Query carries `interpretation`, `intent`, `sql`; interpretation <=1,024 bytes. Only one action/query per turn. Schema/definitions and fixed snapshot coverage accompany prompt. Ordinary `sql_error` may be repaired within the *same* global budgets; denied operations remain recorded and spend an attempt. No provider-controlled parallel tool execution. Each successful result gets code-generated `q1` etc.; failures have trace events but are not citable evidence. Clarification returns no speculative answer.

Final output (all keys required, additional keys rejected): `status` in answered/needs_clarification/insufficient_data/budget_exhausted, `interpretation` string, `answer` string, `findings` array of `{text, evidence_ids:[string]}`, `evidence` array of `{id, intent, sql, columns, rows}`, `limitations` array of strings, `trace_id` UUID. Max 8 findings/8 limitations, strings <=1,024 bytes, answer <=2,048 bytes; model narrative <=8 KiB and assembled output <=48 KiB. Code assembles evidence and trace_id; model cannot invent or rewrite results. Validate every cited ID exists and answered requires at least one successful evidence result and a citation. This is provenance checking, not proof the answer follows from the numbers. Non-answer statuses must not contain uncited numeric claims; deterministic budget/insufficient fallback explains reason. Explicit infrastructure/provider errors use `{:error, Error}` and MCP isError, not a fabricated answered/insufficient result. Snapshot-too-large is insufficient_data with a clear coverage limitation, not provider success.

## Independent Jev review

Config `analytics_review.mode = :off | :shadow | :enforce`; when review configured default shadow. Unconfigured review in shadow records `review_unavailable` and proceeds unreviewed; output limitation says so. Enforce with unavailable/failed/malformed reviewer fails with review_unavailable, never auto-approves. Off records disabled. Reviewer sees question, interpretation, metric definitions, SQL intent/proposal and preceding successful evidence, not raw provider envelopes, credentials or additional data. `decide/3` asks one typed judgment: proceed/revise_query/clarify_with_user and bounded reason. Use question key `query_review` with choices `proceed`, `revise_query`, `clarify_with_user`; consume `answers.query_review.choice` as the judgment. Existing Decisions responses may include confidence/probabilities (validate types and bound size), not an assumed free-text reasoning response. Request a second bounded typed question only if supported by the configured API; otherwise record a code-generated reason derived from choice, not fabricated provider rationale. Reject missing/wrong choices or unexpected question keys.

Shadow records each judgment/failure but never changes analyst messages, control flow, or final answer based on it. Enforce proceed executes; revise feeds reason back and spends model/review/query-proposal budgets; clarify returns needs_clarification. Maximum three reviewed proposals regardless of retries; no approval replaces SQL enforcement. Reviewer cost counts against same run/daily caps. Jev is experimental advisory reasoning, not a security boundary or guaranteed correctness improvement.

## Traces, privacy and failure behavior

Task 2 adds `analytics_traces` (UUID id, user_id FK, bounded JSON payload, expires_at, inserted_at; index user_id/expires_at). Store question, interpretation, schema version/as_of/timezone, SQL intent/query, compact successful results/error codes, reviewer judgments, call usage/timings, final status. No raw snapshots, notes, full prompts/provider payloads, auth headers, SQL exception stack traces or secrets in logs. Prompt itself is sensitive user data. Payload <=64 KiB; store evidence once and final output by evidence reference (do not duplicate query results). Reject overflow explicitly, never save a fake complete trace. Retain seven days and at most 20 traces per user, prune on scoped write/read; expired records inaccessible immediately and provide scheduled deletion via existing Oban pattern. Trace write failure returns trace_unavailable instead of an inspectability claim. Failed runs may retain bounded error traces without claiming final output success.

Access only through scope-checked `Trace.fetch` and a local operator-only `mix burpee_trainer.analytics.trace --user-id ID --trace-id UUID` (construct trusted Scope from operator-selected account; this is not model permission). CLI emits sensitive owner data to stdout only on explicit request, never globally lists traces. No trace UI or unauthenticated HTTP route. Owner deletion must cascade or delete trace rows; test it.

## Evaluation and rollout

Compare A existing read-only MCP tools, B same SQL analyst review off, C same analyst with Jev enforce; also measure shadow catches offline without claiming it redirects behavior. Deterministic multi-user fixtures across two datasets; 25 independently expected cases, five held out from prompt tuning. Expectations specify numbers/status/allowed evidence, not exact SQL or model self-grading. Categories: mixed types, warmups, actual/planned, sparse history, duration comparability, DST/local boundaries, misleading causality/premise, ambiguous improvement, contamination, denied operations. Score correctness, clarification/abstention, evidence fidelity, catches/false objections, billed cost and latency; report denominators and missing observations. Recorded protocol tests are not empirical model-quality benchmarks. Live runs require explicit opt-in and mandatory positive paid-call budget enforced before every analyst/reviewer/baseline call, no default spend. No live calls authorized by this document.

Rollout gates: task-1 malicious SQL/isolation/resource/cleanup tests plus security review; task-2 recorded loop/review/budget tests plus behavioral review; task-3 independent fixture scoring review; task-4 MCP authorization/schema integration and runtime runbook, then `mix precommit` and `mix ci`. Final independent security/correctness review before acceptance. Fail closed at deployment if sandbox proof cannot run; do not expose analyze merely because MCP registry compiles.
