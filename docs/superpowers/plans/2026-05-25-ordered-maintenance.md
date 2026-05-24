# Ordered Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the next maintenance/refactor tasks in priority order: asset setup, workspace cleanup, PlanEditor follow-up, StatsLive research, and SessionLive reliability research.

**Architecture:** Keep operational fixes separate from refactors. Use small commits for concrete code changes and write research/design artifacts before larger LiveView refactors.

**Tech Stack:** Elixir, Phoenix, esbuild, npm assets, jj workspaces, ExUnit.

---

## Task 1: Fix Asset Setup

**Files:**

- Modify: `mix.exs`

- [ ] **Step 1: Update assets.setup alias**

Change `assets.setup` in `mix.exs` from:

```elixir
"assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
```

to:

```elixir
"assets.setup": [
  "tailwind.install --if-missing",
  "esbuild.install --if-missing",
  "cmd --cd assets npm install"
],
```

- [ ] **Step 2: Verify assets build**

Run:

```bash
mix assets.setup
mix assets.build
```

Expected: esbuild resolves `chart.js/auto` and `chartjs-adapter-date-fns` without errors.

- [ ] **Step 3: Verify project**

Run:

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 4: Commit and push master**

```bash
jj describe -m "fix(assets): install npm dependencies during setup"
jj bookmark set master -r @
jj git push -b master
jj new
```

## Task 2: Clean Completed jj Workspaces

**Files:** none.

- [ ] **Step 1: Inspect workspaces**

Run:

```bash
jj workspace list
```

- [ ] **Step 2: Forget completed workspaces**

Forget only these completed workspaces:

```bash
jj workspace forget burpee_trainer-skill-refactor
jj workspace forget burpee_trainer-plan-editor-state
```

Do not forget `burpee_trainer-home-screen`.

- [ ] **Step 3: Remove directories**

From `/home/aktersnurra/projects/vibe`:

```bash
rm -rf burpee_trainer-skill-refactor burpee_trainer-plan-editor-state
```

- [ ] **Step 4: Verify workspace list**

Run:

```bash
jj workspace list
```

Expected: the two completed workspaces are gone.

## Task 3: PlanEditor Cleanup Recon

**Files:**

- Create: `docs/superpowers/specs/2026-05-25-plan-editor-cleanup-followup.md`

- [ ] **Step 1: Audit remaining loose assigns**

Run:

```bash
rg "assigns\.(plan_input|manual_edit|solver_error|solver_solution|expanded_blocks|open_block_menu)|@(plan_input|manual_edit|solver_error|solver_solution|expanded_blocks|open_block_menu)" lib/burpee_trainer_web/live/plans_live/edit.ex
```

- [ ] **Step 2: Write follow-up spec**

Write `docs/superpowers/specs/2026-05-25-plan-editor-cleanup-followup.md` with:

- remaining template-facing assigns;
- which assigns can safely be replaced with `@editor` reads;
- whether rendering extraction is now the right next slice;
- recommendation: implement now only if it is a small safe slice, otherwise defer.

- [ ] **Step 3: Commit spec**

```bash
jj file track --include-ignored docs/superpowers/specs/2026-05-25-plan-editor-cleanup-followup.md
jj describe -m "docs(plans): audit editor state follow-up"
jj new
```

## Task 4: StatsLive Refactor Research

**Files:**

- Create: `docs/superpowers/specs/2026-05-25-stats-live-refactor-research.md`

- [ ] **Step 1: Inspect StatsLive structure**

Run a focused symbol/definition scan for `lib/burpee_trainer_web/live/stats_live.ex`.

- [ ] **Step 2: Identify extraction boundary**

Document which functions are data shaping, chart series building, UI rendering helpers, or LiveView event plumbing.

- [ ] **Step 3: Write research/spec artifact**

Write `docs/superpowers/specs/2026-05-25-stats-live-refactor-research.md` with:

- recommended pure module boundary;
- proposed tests;
- risks;
- whether to implement immediately or plan first.

- [ ] **Step 4: Commit spec**

```bash
jj file track --include-ignored docs/superpowers/specs/2026-05-25-stats-live-refactor-research.md
jj describe -m "docs(stats): research LiveView extraction boundary"
jj new
```

## Task 5: Session Runner Reliability Research

**Files:**

- Create: `docs/superpowers/specs/2026-05-25-session-runner-reliability.md`

- [ ] **Step 1: Inspect session boundary**

Review `lib/burpee_trainer_web/live/session_live.ex` and session hook JS.

- [ ] **Step 2: Identify reliability slice**

Document the smallest reliability improvement around event payload parsing, completion save flow, or client/server state boundary.

- [ ] **Step 3: Write research/spec artifact**

Write `docs/superpowers/specs/2026-05-25-session-runner-reliability.md` with:

- current boundary;
- likely failure modes;
- recommended next implementation slice;
- tests needed.

- [ ] **Step 4: Commit spec**

```bash
jj file track --include-ignored docs/superpowers/specs/2026-05-25-session-runner-reliability.md
jj describe -m "docs(session): research runner reliability slice"
jj new
```

## Final Verification

- [ ] Run:

```bash
jj st
jj log -r 'ancestors(@, 8)' --no-graph
```

Expected: clean working copy or only empty `@` after completed commits.
