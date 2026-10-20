# Analytics agent implementation plan

Design contract: `docs/specs/2026-10-20-analytics-agent-design.md`.
Feature base `f8eb62c7`; exclusive jj workspace `analytics-agent`. Planning is not production implementation. Parent orchestrates serial owners and independent reviewers; no concurrent writers, raw git, push, deploy, paid calls, or worker delegation.

## Planning gate (completed)

Read project instructions and actual MCP/Coach/History/Workouts contracts. Existing MCP baseline passed 57 tests. Installed Exqlite 0.42.0 cannot provide named function policy, tail rejection, or hard process memory/deadline limits. Owner approved a separate OS-isolated helper after escalation. Python standard library + bubblewrap provides the smallest no-pip implementation, with Linux/Python/SQLite/runtime requirements and no unconfined fallback. Local probes assert operation/function/tail behavior, active NIF cancellation, default-deny sandbox SQL, memory rejection, CPU kill, and wall kill/reap. Full logs, command history, briefs, and progress live under `.docs/analytics-agent/`.

## Frozen seams

- `Analytics.Snapshot.build(scope, now: now)` returns immutable `%Snapshot{rows, as_of, timezone, schema_version: 1}`. Only approved session scalars, no user IDs/free text in helper input. Scope validated in trusted Ecto, >5,000 candidates or >1 MiB refuses.
- `Analytics.Schema.columns/0`, `.text/0`, `.version/0`: exact 14-column schema in design; MCP resource URI `burpee://analytics/schema`.
- `Analytics.Executor.query(snapshot, sql, timeout_ms: <=1_000)` returns `{:ok, %{columns, rows, duration_ms}} | {:error, atom}`; default-deny helper and hard sandbox bound. No production DB handle/path.
- `BurpeeTrainer.Analytics.analyze(scope, prompt, opts \\ [])` returns typed validated output or `%Workouts.Error{}`; Coach-enabled gate, same ledger/client, no mutation tools.
- `Analytics.Trace.fetch(scope, uuid)` returns owned/unexpired bounded trace or not_found; final output refers only to generated successful evidence IDs.
- Jev uses `Client.decide/3`, question `query_review`, choice proceed/revise_query/clarify_with_user, with the same choice/criteria wire shape as `Coach.Selector`. Shadow cannot change behavior; enforce cannot auto-approve a failure.
- Output statuses answered/needs_clarification/insufficient_data/budget_exhausted; infrastructure/provider errors remain explicit errors. MCP adapter does not choose limits/mode/user.

## Task 1 — snapshot and isolated executor

Ownership: `lib/burpee_trainer/analytics/{schema,snapshot,executor,helper_guardian}.ex`, `priv/analytics/sqlite_helper.py`, `test/burpee_trainer/analytics/{snapshot,executor}_test.exs`, `test/analytics/sqlite_helper_test.py`; minimal application supervision/runtime config only for helper admission/health. No analyst/MCP/eval changes. Document necessary OS requirements in the design if implementation reveals packaging specifics; substantive changes require parent decision.

1. Promote planning probes into tests, write failing scoped projection/malicious query/resource tests first.
2. Implement captured-time, one-transaction snapshot using AuthoritativeSession, History and UserTime (not broad MCP session encoding, which includes notes).
3. Implement Python protocol and function-aware default-deny authorizer; all limits from design, strict one-statement execute semantics, incremental bounded output.
4. Implement fixed-argv sandbox guardian with caller monitoring, max-two admission, monotonic deadline, explicit kill/reap and bounded stdout/stderr. Health check uses actual sandbox, fail closed.
5. Test all actions/unknown functions/schema reads/tails/comment variants, allowed aggregate/control cases, other-user sentinel, snapshot stability, CPU/memory/wall limits, no host DB/network, actual helper child cleanup, overflow and unsupported-platform/config failures.
6. Run focused Elixir and Python suites; independent security/spec review before Task 2.

## Task 2 — analyst, review, trace

Ownership: `lib/burpee_trainer/analytics.ex`, `lib/burpee_trainer/analytics/{analyst,prompt,review,output,limits,trace,trace_record,trace_cleanup_job}.ex`, generated migration for analytics_traces, `lib/mix/tasks/burpee_trainer.analytics.trace.ex`, `test/burpee_trainer/analytics/{analyst,review,output,trace}_test.exs`, `test/support/analytics_provider_plug.ex`. Narrow Client/Ledger or Oban config edits only if required by existing interfaces; no dependency/executor redesign, MCP adapter, or eval corpus.

1. Red tests for strict outputs/citations, no-call permission gate, query/repair/clarify/insufficient/budget statuses, provider and helper failures.
2. Implement bounded controller and provider schema with code-generated evidence. Limits in design are ceilings, never provider/user overrides.
3. Use existing Client.chat/decide and same run_id ledger `run_cap: 8`, purposes analytics/analytics_review in user bucket, explicit deadline and tightened timeouts.
4. Implement off/shadow/enforce with recorded choice envelopes; shadow failures/judgments stay out of analyst context; enforce revise/clarify feeds bounded control flow, fail closed on unavailable review.
5. Implement scope-checked 7-day/20-per-user/64-KiB trace storage/expiry/deletion, no duplicated evidence/raw snapshots/provider payloads; operator-only explicit scoped trace CLI.
6. Recorded Req tests only, zero paid calls. Independent behavioral/spec review before Task 3.

## Task 3 — independent evaluation

Ownership: `lib/burpee_trainer/evals/analytics/{corpus,runner,score}.ex`, `lib/mix/tasks/burpee_trainer.analytics.eval.ex`, `test/burpee_trainer/evals/analytics_test.exs`, `test/fixtures/analytics/*`, `docs/guides/analytics-evaluation.md`. No edits to executor/analyst/Client/MCP absent approved fix handoff.

Create 25 cases with independent expected numeric/status outcomes over two datasets and explicit five-case held-out partition. Baseline A uses read-only existing MCP tools only; B uses analyst review off; C same analyst enforce. Default mode fully offline recorded protocol checks; model benchmark requires separate explicit `--live --max-calls N` and user opt-in with no default spend. Enforce global paid-call ceiling across arms/reviewer/retries; daily ledger remains intact. Emit per-case evidence fidelity, status/correctness, reviewer catches and false objections, usage/cost/latency and missing-observation markers. Score with deterministic code, not SQL string equality or model judgment. Review independent expectations/contamination before Task 4.

## Task 4 — integration only

Ownership: `lib/burpee_trainer/mcp/tools/analyze.ex`, `lib/burpee_trainer/mcp/analytics_schema.ex`, narrow `lib/burpee_trainer/mcp.ex` tool/resource/outputSchema wiring, `test/burpee_trainer/mcp/analytics_test.exs`, narrow `test/burpee_trainer_web/controllers/mcp_controller_test.exs`, `docs/guides/analytics-agent.md`, `docs/README.md` link, deployment packaging/runtime config necessary for approved helper only. Do not alter underlying contracts or add Coach.Agent tool exposure.

MCP `analyze` accepts exactly `{prompt: string}` <=4,096 UTF-8 bytes; trusted scope only. Return structuredContent and matching JSON text through existing tool_result path, isError for context errors; advertise matching outputSchema and optional readOnlyHint without implying no ledger/trace writes. Preserve metadata for existing tools. Resource explains schema, actual/planned/warmup/date/type limitations and supported SQL. Test bearer ownership, coach-disabled zero calls, trace ID isolation, outputSchema/resource listing, limits/error behavior. Document runtime package requirements and service-identity sandbox preflight, retention/privacy/CLI and opt-in eval. Run focused tests then full gates.

## Validation and handoff per task

Use TDD, source-named tests, DataCase/ConnCase async:false. Pure tests async:true. Read AGENTS.md/CLAUDE.md and task-local brief. Inspect actual frozen interfaces before extending them; contact parent on substantive gaps. Never mutate deps source or suppress baseline checks. Use root deps only read-only; workspace-local build. If using a deps symlink, remove it before jj snapshot/commit (it otherwise becomes a tracked file).

Focused commands (after reading `mix help test`):

```sh
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test test/burpee_trainer/analytics/snapshot_test.exs test/burpee_trainer/analytics/executor_test.exs
python3 -m unittest discover -s test/analytics -p '*_test.py'
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test test/burpee_trainer/analytics
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test test/burpee_trainer/evals/analytics_test.exs
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test test/burpee_trainer/mcp_test.exs test/burpee_trainer/mcp test/burpee_trainer_web/controllers/mcp_controller_test.exs
ERL_FLAGS='+S 4:4' MIX_ENV=test mix precommit
ERL_FLAGS='+S 4:4' MIX_ENV=test mix ci
```

Do not invoke files not yet implemented. Capture real commands/results, files, jj change/revision, review findings and residual risks in `.docs/analytics-agent/progress.md` and each component artifact. Use conventional jj descriptions, produce task-local diff against feature base, leave empty new change after handoff. Parent runs independent read-only review between exclusive writers, then final fresh security/correctness reviews. Only a serial fix owner may implement accepted findings. No stage/push/deploy or live model run implied by passing offline tests.
