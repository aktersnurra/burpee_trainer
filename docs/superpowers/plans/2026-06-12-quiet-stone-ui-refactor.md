# Quiet Stone UI Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin and simplify the authenticated app into a light-default Quiet stone visual system: Notion-like restraint, Anthropic-adjacent warmth, Geist refined typography, and action-first training surfaces.

**Architecture:** Centralize the visual identity in `assets/css/app.css`, then make shared shell and page templates consume those tokens through existing Tailwind/CSS-variable utilities. Keep behavior unchanged; this is a visual-system and surface-hierarchy refactor, not a data/model rewrite.

**Tech Stack:** Phoenix 1.8, LiveView, HEEx templates, Tailwind CSS v4, daisyUI theme variables, Geist font, ExUnit + Phoenix.LiveViewTest.

---

## File map

- Modify `assets/css/app.css`: Quiet stone palette, warm-charcoal dark mode, typography utilities, shared button/surface helper classes if needed.
- Modify `lib/burpee_trainer_web/components/layouts.ex`: quieter app shell, nav, theme toggle, mobile tab treatment.
- Modify `lib/burpee_trainer_web/live/overview_live.ex`: action-first Home visual hierarchy using the new system.
- Modify `lib/burpee_trainer_web/live/workouts_live.ex`: reduce workout browsing chrome while preserving existing IDs/events.
- Modify `lib/burpee_trainer_web/live/stats_live/render.html.heex` and related `StatsLive` render helpers if needed: warm reading surface, less card bloat.
- Modify `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex` and related partials: align plan editor surfaces with Quiet stone rules.
- Modify `lib/burpee_trainer_web/live/session_live.ex`: keep runner legible, but switch from old warm-paper/dark-blue assumptions to Quiet stone tokens.
- Modify tests under `test/burpee_trainer_web/live/`: assert stable IDs, high-level page structure, and absence of old loud UI language where practical.
- Run `mix precommit` as final verification.

---

### Task 1: Establish Quiet stone theme tokens

**Files:**

- Modify: `assets/css/app.css`
- Test: command-level CSS/token checks

- [ ] **Step 1: Add a token check command before editing**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
rg --line-number "#4A9EFF|electric blue|--session-bg|--session-accent" assets/css/app.css UI.md README.md
```

Expected: current CSS/docs still include the old blue/dark language and existing `--session-*` tokens.

- [ ] **Step 2: Replace the daisyUI dark theme palette with Quiet stone defaults**

In `assets/css/app.css`, update the `@plugin "../vendor/daisyui-theme"` block so the default theme uses warm light values:

```css
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  default: true;
  prefersdark: true;
  color-scheme: "light";
  --color-base-100: #F4F2EE;
  --color-base-200: #FAF8F3;
  --color-base-300: #EFECE4;
  --color-base-content: #20201D;
  --color-primary: #20201D;
  --color-primary-content: #FAF8F3;
  --color-secondary: #A77B5D;
  --color-secondary-content: #FFF8F0;
  --color-accent: #A77B5D;
  --color-accent-content: #FFF8F0;
  --color-neutral: #DAD6CE;
  --color-neutral-content: #20201D;
  --color-info: #6F7F8F;
  --color-info-content: #F8F6F1;
  --color-success: #6F7D55;
  --color-success-content: #F8F6F1;
  --color-warning: #A77B5D;
  --color-warning-content: #FFF8F0;
  --color-error: #A55643;
  --color-error-content: #FFF8F0;
  --radius-selector: 0.5rem;
  --radius-field: 0.5rem;
  --radius-box: 0.875rem;
  --size-selector: 0.21875rem;
  --size-field: 0.21875rem;
  --border: 1px;
  --depth: 0;
  --noise: 0;
}
```

- [ ] **Step 3: Update semantic Tailwind theme tokens**

In the `@theme` block, keep Geist and replace raised/nav/border/muted tokens:

```css
@theme {
  --font-sans: "Geist", ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
  --font-mono: "Geist", ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
  --color-base-nav:          #F4F2EE;
  --color-base-raised:       #FAF8F3;
  --color-base-border:       #DAD6CE;
  --color-base-border-hover: #CFC8BC;
  --color-base-muted:        #74716A;
}
```

- [ ] **Step 4: Update root/body light and dark backgrounds**

Replace root/body background rules with:

```css
:root {
  color-scheme: light;
  background: #F4F2EE;
}

body {
  background: #F4F2EE;
}

[data-theme="dark"] {
  color-scheme: dark;
  background: #181614;
}

[data-theme="dark"] body {
  background: #181614;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    color-scheme: light;
    background: #F4F2EE;
  }

  :root:not([data-theme]) body {
    background: #F4F2EE;
  }
}
```

This makes light the default even on dark OS preferences; explicit app dark mode still works.

- [ ] **Step 5: Replace session-surface token blocks**

Set light session tokens:

```css
#burpee-session,
.session-surface {
  font-family: "Geist", ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
  --session-bg: #F4F2EE;
  --session-surface: #FAF8F3;
  --session-surface-alt: #EFECE4;
  --session-ink: #20201D;
  --session-muted: #74716A;
  --session-soft-muted: #9A9489;
  --session-border: #DAD6CE;
  --session-track: #DAD6CE;
  --session-ring-track: #DAD6CE;
  --session-accent: #A77B5D;
  --session-accent-strong: #8F5F46;
  --session-series-six: var(--session-ink);
  --session-series-seal: var(--session-accent);
  --session-countin-bg: var(--session-ink);
  --session-countin-ink: #FAF8F3;
}
```

Set dark session tokens:

```css
[data-theme="dark"] #burpee-session,
[data-theme="dark"] .session-surface {
  --session-bg: #181614;
  --session-surface: #211F1B;
  --session-surface-alt: #2A2722;
  --session-ink: #F3EEE6;
  --session-muted: #B8AEA1;
  --session-soft-muted: #8F867A;
  --session-border: #39342D;
  --session-track: #39342D;
  --session-ring-track: #39342D;
  --session-accent: #C08A68;
  --session-accent-strong: #D09A78;
  --session-series-six: var(--session-ink);
  --session-series-seal: var(--session-accent);
  --session-countin-bg: var(--session-ink);
  --session-countin-ink: #181614;
}
```

Preserve existing non-color rules below these blocks unless they hard-code the old blue/dark identity.

- [ ] **Step 6: Add typography helper primitives**

Add reusable CSS utilities near the session token section:

```css
.qs-tabular {
  font-variant-numeric: tabular-nums;
}

.qs-heading-tight {
  letter-spacing: -0.045em;
}

.qs-section-tight {
  letter-spacing: -0.025em;
}

.qs-meta {
  letter-spacing: 0.06em;
  text-transform: uppercase;
}
```

- [ ] **Step 7: Verify tokens compile**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix assets.build
```

Expected: command exits 0.

- [ ] **Step 8: Commit token phase**

Run:

```bash
jj describe -m "style(ui): introduce quiet stone theme tokens"
jj new
```

Expected: current change has a meaningful description and a fresh empty working copy is created for Task 2.

---

### Task 2: Refine shared app shell

**Files:**

- Modify: `lib/burpee_trainer_web/components/layouts.ex`
- Test: existing LiveView tests plus shell-focused assertions if needed

- [ ] **Step 1: Inspect current shell output points**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
rg --line-number "nav_icon|bottom_tab|theme_toggle|session_surface_page|base-nav|session_nav" lib/burpee_trainer_web/components/layouts.ex
```

Expected: find desktop nav, mobile tab nav, spacer, and theme toggle helpers.

- [ ] **Step 2: Quiet the desktop nav**

In `Layouts.app/1`, update the desktop `<nav>` classes to use warm transparent shell styling:

```elixir
<nav class={[
  "hidden sm:flex items-center justify-center gap-2 px-4 py-3 border-b",
  @session_surface_page? &&
    "session-surface border-[var(--session-border)] bg-[var(--session-bg)]/95 text-[var(--session-ink)]",
  !@session_surface_page? && "border-base-border bg-base-nav text-base-content"
]}>
```

- [ ] **Step 3: Quiet the mobile bottom nav**

Update the mobile nav classes:

```elixir
<nav class={[
  "fixed bottom-0 inset-x-0 z-50 sm:hidden flex justify-around border-t pb-safe backdrop-blur",
  @session_surface_page? &&
    "session-surface h-[84px] items-start border-[var(--session-border)] bg-[var(--session-bg)]/95",
  !@session_surface_page? && "h-16 border-base-border bg-base-nav/95"
]}>
```

Also update the mobile spacer from `h-[92px]` to `h-[84px]` for session surfaces.

- [ ] **Step 4: Make active nav calmer**

Update `nav_icon/1` active/inactive classes so active state uses ink and a thin clay indicator, not a heavy fill:

```elixir
class={[
  "relative inline-flex items-center justify-center w-10 h-10 rounded-xl transition-colors",
  @session_nav? && @active && "text-[var(--session-ink)]",
  @session_nav? && !@active &&
    "text-[var(--session-muted)] hover:text-[var(--session-ink)] hover:bg-[var(--session-surface-alt)]/60",
  !@session_nav? && @active && "text-base-content bg-base-raised",
  !@session_nav? && !@active &&
    "text-base-muted hover:text-base-content hover:bg-base-raised"
]}
```

Change the active indicator span to:

```elixir
<span
  :if={@session_nav? && @active}
  class="absolute left-1/2 top-[-13px] h-0.5 w-7 -translate-x-1/2 rounded-full bg-[var(--session-accent)]"
  aria-hidden="true"
/>
```

- [ ] **Step 5: Make bottom tabs calmer**

Update `bottom_tab/1` classes:

```elixir
class={[
  "relative inline-flex flex-col items-center transition-colors",
  @session_nav? && "h-[84px] min-w-0 flex-1 justify-start gap-1.5 pt-5",
  !@session_nav? && "h-14 w-16 shrink-0 justify-center gap-0.5",
  @session_nav? && @active && "font-medium text-[var(--session-ink)]",
  @session_nav? && !@active && "font-medium text-[var(--session-muted)]",
  !@session_nav? && @active && "text-base-content",
  !@session_nav? && !@active && "text-base-muted"
]}
```

Change the active indicator to:

```elixir
<span
  :if={@session_nav? && @active}
  class="absolute left-1/2 top-0 h-0.5 w-7 -translate-x-1/2 rounded-full bg-[var(--session-accent)]"
  aria-hidden="true"
/>
```

Use smaller icon/text sizing:

```elixir
<span class={[@session_nav? && "[&_svg]:size-6", !@session_nav? && ""]}>
  {render_slot(@inner_block)}
</span>
<span class={[@session_nav? && "text-xs", !@session_nav? && "text-[10px] font-medium"]}>
  {@label}
</span>
```

- [ ] **Step 6: Demote theme toggle**

Update `theme_toggle/1` class to avoid competing with page actions:

```elixir
class={[
  "fixed right-4 top-4 z-40 flex size-8 items-center justify-center rounded-full border transition sm:right-[calc(50%_-_16rem)] sm:top-16",
  @session_nav? &&
    "session-surface border-[var(--session-border)] text-[var(--session-muted)] hover:text-[var(--session-ink)] hover:bg-[var(--session-surface-alt)]",
  !@session_nav? &&
    "border-base-border text-base-muted hover:text-base-content hover:bg-base-raised"
]}
```

- [ ] **Step 7: Run shell-adjacent tests**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/workouts_live_test.exs test/burpee_trainer_web/live/session_live_test.exs
```

Expected: tests pass. If failures are only text/class assumptions from old styling, update tests to assert stable IDs and behavior instead.

- [ ] **Step 8: Commit shell phase**

Run:

```bash
jj describe -m "style(ui): quiet shared app shell"
jj new
```

---

### Task 3: Refactor Home as the action-first Quiet stone surface

**Files:**

- Modify: `lib/burpee_trainer_web/live/overview_live.ex`
- Test: create or modify `test/burpee_trainer_web/live/overview_live_test.exs`

- [ ] **Step 1: Add Home structure tests**

If `test/burpee_trainer_web/live/overview_live_test.exs` does not exist, create it with:

```elixir
defmodule BurpeeTrainerWeb.OverviewLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "home renders quiet action-first structure", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Default Work"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-status-strip")
    assert has_element?(view, "#home-primary-workout")
    assert has_element?(view, "#home-start-workout[href='/session/#{plan.id}']")
    assert has_element?(view, "#home-log-session")

    html = render(view)
    assert html =~ "Default Work"
    refute html =~ "12-week"
    refute html =~ "Dashboard"
  end
end
```

If the file already exists, add only the test body above and reuse the existing setup.

- [ ] **Step 2: Run Home test and verify it fails before markup changes**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/overview_live_test.exs
```

Expected: fails because one or more of `#home-status-strip`, `#home-primary-workout`, `#home-start-workout`, or `#home-log-session` is missing.

- [ ] **Step 3: Update Home root layout**

In `OverviewLive.render/1` or its HEEx body in `overview_live.ex`, use this outer shape:

```heex
<Layouts.app flash={@flash} current_user={@current_user} current_page={:home}>
  <div id="home-page" class="session-surface mx-auto max-w-lg pb-24 text-[var(--session-ink)]">
    <section id="home-status-strip" class="mb-10 space-y-3 text-sm text-[var(--session-muted)]">
      <!-- existing weekly/streak/level data rendered quietly here -->
    </section>

    <section id="home-primary-workout" class="space-y-5">
      <!-- primary workout card/action here -->
    </section>

    <!-- existing log modal remains below -->
  </div>
</Layouts.app>
```

Preserve existing event handlers and assigns.

- [ ] **Step 4: Render status as ambient context**

Inside `#home-status-strip`, render weekly minutes and streak/level in a flat layout:

```heex
<div class="flex items-center justify-between gap-4">
  <p class="qs-tabular">
    <span class="text-[var(--session-ink)]">{round(@this_week.minutes)}</span>
    <span>/ {round(@goal_min)} min this week</span>
  </p>
  <p class="text-right">{length(@trained_days)} trained days</p>
</div>
<div class="flex items-center justify-between gap-4 border-t border-[var(--session-border)] pt-3">
  <p>{@level_status.streak_weeks || 0} week streak</p>
  <p class="qs-meta text-[11px] text-[var(--session-soft-muted)]">Level {@level_status.current_level}</p>
</div>
```

If field names differ, use the existing rendered values already used in `OverviewLive` and keep the IDs/classes.

- [ ] **Step 5: Render primary workout as the only strong card**

Inside `#home-primary-workout`, render:

```heex
<p class="text-xs text-[var(--session-muted)]">Ready</p>
<h1 class="qs-heading-tight text-4xl font-semibold leading-none text-[var(--session-ink)]">
  Start before<br />you think.
</h1>

<div :if={@last_plan} class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] p-5">
  <p class="mb-2 text-sm text-[var(--session-muted)]">Default workout</p>
  <h2 class="qs-section-tight text-2xl font-semibold text-[var(--session-ink)]">{@last_plan.name}</h2>
  <p class="mt-1 text-sm text-[var(--session-muted)]">Pick up where you left off.</p>
  <.link
    id="home-start-workout"
    navigate={~p"/session/#{@last_plan.id}"}
    class="mt-5 flex h-12 items-center justify-center rounded-xl bg-[var(--session-ink)] px-4 text-sm font-semibold text-[var(--session-bg)] transition hover:opacity-90"
  >
    Start
  </.link>
</div>
```

Add a no-plan fallback with `id="home-start-workout"` linking to `~p"/workouts"` and text `Choose a workout`.

- [ ] **Step 6: Demote secondary actions**

Render log and change-workout actions as quiet text links below the primary card:

```heex
<div class="flex items-center gap-4 text-sm text-[var(--session-muted)]">
  <.link navigate={~p"/workouts"} class="hover:text-[var(--session-ink)]">Change workout</.link>
  <button id="home-log-session" type="button" phx-click="open_log_modal" class="hover:text-[var(--session-ink)]">
    Log past session
  </button>
</div>
```

- [ ] **Step 7: Run Home tests**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/overview_live_test.exs
```

Expected: pass.

- [ ] **Step 8: Commit Home phase**

Run:

```bash
jj describe -m "style(home): make home quiet action-first"
jj new
```

---

### Task 4: Apply Quiet stone to Workouts browsing

**Files:**

- Modify: `lib/burpee_trainer_web/live/workouts_live.ex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Add a style-structure assertion to existing Workouts test**

In test `renders workout page with featured instrument and rounded list`, add:

```elixir
assert has_element?(view, "#workouts-page.session-surface")
assert has_element?(view, "#workouts-list")
assert has_element?(view, "[data-workout-row]")
```

Keep existing assertions for IDs like `#workouts-featured-card`, `#workouts-options-section`, and `#workouts-filter-panel` unless the implementation intentionally removes those IDs. If markup is flattened, preserve IDs on the new sections.

- [ ] **Step 2: Run Workouts tests and verify baseline**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: pass before styling if IDs already exist, or fail only for `#workouts-page.session-surface`.

- [ ] **Step 3: Update Workouts page root**

Wrap the page body with:

```heex
<div id="workouts-page" class="session-surface mx-auto max-w-lg space-y-8 pb-24 text-[var(--session-ink)]">
```

- [ ] **Step 4: Quiet featured workout section**

For `#workouts-featured-card`, use a single restrained filled surface:

```heex
<section
  id="workouts-featured-card"
  class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] p-5"
>
```

Use `text-[var(--session-muted)]` for labels, `qs-section-tight` for workout names, and ink-filled Start buttons.

- [ ] **Step 5: Flatten filters and options**

For `#workouts-filter-panel`, avoid bright pills. Use thin bordered buttons:

```heex
class={[
  "rounded-full border px-3 py-1.5 text-sm transition",
  active && "border-[var(--session-ink)] text-[var(--session-ink)]",
  !active && "border-[var(--session-border)] text-[var(--session-muted)] hover:text-[var(--session-ink)]"
]}
```

- [ ] **Step 6: Make list rows scannable**

For each `[data-workout-row]`, prefer row/rule styling over heavy cards:

```heex
class="group border-t border-[var(--session-border)] py-4 first:border-t-0"
```

Keep explicit play links like `#workout-play-plan-#{plan.id}` visible and tappable.

- [ ] **Step 7: Run Workouts tests**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: pass.

- [ ] **Step 8: Commit Workouts phase**

Run:

```bash
jj describe -m "style(workouts): apply quiet stone browsing surface"
jj new
```

---

### Task 5: Apply Quiet stone to Stats reading surface

**Files:**

- Modify: `lib/burpee_trainer_web/live/stats_live/render.html.heex`
- Modify if needed: `lib/burpee_trainer_web/live/stats_live/*.heex`
- Test: stats LiveView tests if present; otherwise focused smoke via all LiveView tests

- [ ] **Step 1: Locate Stats tests**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
fd 'stats.*test' test || true
```

Expected: list stats tests if present. Use those in later steps; if none exist, use `mix test test/burpee_trainer_web/live` as the smoke suite.

- [ ] **Step 2: Update Stats root**

In `stats_live/render.html.heex`, keep the root ID/data attribute and use:

```heex
<div
  data-stats-page
  class="session-surface mx-auto max-w-lg space-y-8 pb-24 text-[var(--session-ink)]"
>
```

- [ ] **Step 3: Demote FAB styling**

Update `#stats-log-button` to be quiet and token-based:

```heex
class="flex size-11 items-center justify-center rounded-full border border-[var(--session-border)] bg-[var(--session-surface)] text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]"
```

- [ ] **Step 4: Replace old blue/bright chart classes in stats partials**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
rg --line-number "4A9EFF|blue-|green-|shadow|gradient" lib/burpee_trainer_web/live/stats_live assets/css/app.css
```

For each match inside `lib/burpee_trainer_web/live/stats_live`, replace with `var(--session-ink)`, `var(--session-accent)`, `var(--session-border)`, or muted text classes according to the design spec.

- [ ] **Step 5: Prefer rules over cards for history sections**

For session-history list containers, use:

```heex
class="divide-y divide-[var(--session-border)] border-y border-[var(--session-border)]"
```

For individual rows, use:

```heex
class="py-4"
```

Do not remove existing IDs or event attributes.

- [ ] **Step 6: Run Stats or LiveView smoke tests**

If stats tests exist, run:

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs
```

Otherwise run:

```bash
mix test test/burpee_trainer_web/live
```

Expected: pass.

- [ ] **Step 7: Commit Stats phase**

Run:

```bash
jj describe -m "style(stats): warm up progress reading surface"
jj new
```

---

### Task 6: Align Plan editor surfaces

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Modify if needed: `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex`
- Test: existing plan editor tests inside `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Run current plan editor tests**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/workouts_live_test.exs --include capture_log
```

Expected: pass. Note any existing failures before visual edits.

- [ ] **Step 2: Update editor root to Quiet stone tokens**

In `render.html.heex`, ensure the main editor wrapper uses:

```heex
class="session-surface mx-auto max-w-2xl space-y-8 pb-24 text-[var(--session-ink)]"
```

- [ ] **Step 3: Separate input and output surfaces**

Use these visual roles:

```heex
<section class="space-y-4 border-t border-[var(--session-border)] pt-6">
```

for flat input/configuration sections, and:

```heex
<section class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] p-5">
```

for generated solution/output sections.

- [ ] **Step 4: Replace bright validation borders**

Search:

```bash
rg --line-number "green-|red-|border-.*success|border-.*error|4A9EFF|blue-" lib/burpee_trainer_web/live/plans_live/edit
```

Replace healthy/default validation states with neutral borders plus text/icon signals. Error states may use muted error text, but avoid full-panel bright borders.

- [ ] **Step 5: Preserve all form IDs and LiveView events**

Before finishing, run:

```bash
rg --line-number "id=|phx-click|phx-submit|phx-change|phx-value" lib/burpee_trainer_web/live/plans_live/edit
```

Confirm no required IDs/events were removed from forms, timeline rows, inspector toggles, or solution actions.

- [ ] **Step 6: Run plan editor tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit Plan editor phase**

Run:

```bash
jj describe -m "style(plans): align editor with quiet stone surfaces"
jj new
```

---

### Task 7: Polish session runner without sacrificing legibility

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Test: `test/burpee_trainer_web/live/session_live_test.exs`

- [ ] **Step 1: Update existing runner style test language**

In `test/burpee_trainer_web/live/session_live_test.exs`, rename the test:

```elixir
test "runner renders quiet stone instrument shell", %{conn: conn, user: user} do
```

Keep the existing assertions for:

```elixir
assert has_element?(view, "#session-runner-client[phx-update=ignore]")
assert has_element?(view, "#ring-container[aria-label='Pause or resume session']")
assert has_element?(view, "svg#ring-svg")
assert has_element?(view, "#set-glyphs[aria-label='Workout sets']")
assert has_element?(view, "#total-done")
assert has_element?(view, "#total-plan")
assert has_element?(view, "#time-left")
```

Add:

```elixir
assert has_element?(view, "#burpee-session.session-surface")
```

- [ ] **Step 2: Run Session tests before edits**

Run:

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer-ui-refactor
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: pass or fail only on the new style assertion if the root lacks `session-surface`.

- [ ] **Step 3: Update runner root classes**

In `session_live.ex`, ensure the runner root includes:

```heex
<div id="burpee-session" class="session-surface min-h-dvh bg-[var(--session-bg)] text-[var(--session-ink)]">
```

If `#burpee-session` already exists, add `session-surface` and remove hard-coded old background/text color classes.

- [ ] **Step 4: Use token colors for ring and progress UI**

Replace old hard-coded blue/green/white ring classes or SVG colors with:

```heex
stroke="var(--session-ink)"
stroke="var(--session-ring-track)"
```

For secondary labels use:

```heex
class="text-[var(--session-muted)]"
```

- [ ] **Step 5: Keep timer numerals tabular**

Add `qs-tabular` to timer/count elements:

```heex
<span id="time-left" class="qs-tabular ...">
<span id="total-done" class="qs-tabular ...">
<span id="total-plan" class="qs-tabular ...">
```

Preserve all IDs exactly.

- [ ] **Step 6: Run Session tests**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit Session phase**

Run:

```bash
jj describe -m "style(session): polish runner with quiet stone tokens"
jj new
```

---

### Task 8: Final cleanup, docs alignment, and verification

**Files:**

- Modify: `UI.md`
- Modify if needed: `README.md`
- Verify: whole project

- [ ] **Step 1: Update UI.md design language**

Replace the old directive near the top of `UI.md`:

```markdown
Design directive: sleek, classy, tasteful. Scandinavian dark. Blue replaces green everywhere.
```

with:

```markdown
Design directive: quiet, warm, tasteful. Light Quiet stone is the default; optional dark mode is warm charcoal. Typography, whitespace, and thin rules carry the interface. Muted clay replaces saturated blue as the rare accent.
```

- [ ] **Step 2: Update README style note if present**

Run:

```bash
rg --line-number "Scandinavian dark|electric blue|blue accent|dark theme" README.md UI.md
```

Replace old style references with Quiet stone wording. Do not rewrite unrelated product docs.

- [ ] **Step 3: Run old-style color scan**

Run:

```bash
rg --line-number "#4A9EFF|electric blue|Scandinavian dark|blue replaces green" assets/css lib README.md UI.md docs/superpowers/specs/2026-06-12-quiet-stone-ui-refactor-design.md
```

Expected: no matches except historical docs that are intentionally not part of current style guidance. If current CSS/templates still match, replace them with Quiet stone tokens.

- [ ] **Step 4: Run focused LiveView tests**

Run:

```bash
mix test test/burpee_trainer_web/live
```

Expected: pass.

- [ ] **Step 5: Run full precommit**

Run:

```bash
mix precommit
```

Expected: pass. If it fails, fix the reported issue and re-run `mix precommit` until it passes.

- [ ] **Step 6: Inspect final jj diff**

Run:

```bash
jj st
jj diff --stat
```

Expected: changes are limited to UI/CSS/templates/tests/docs for the Quiet stone refactor.

- [ ] **Step 7: Commit final cleanup phase**

Run:

```bash
jj describe -m "docs(ui): align style guide with quiet stone refactor"
```

Do not run `jj new` after the final task unless continuing with another change.

---

## Plan self-review

- Spec coverage: theme tokens, light default, optional warm dark mode, Geist refined typography, reduced cards, action-first Home, Workouts/Stats/Plan editor/Session alignment, docs update, and verification are all mapped to tasks.
- Placeholder scan: no unresolved placeholder markers or open-ended implementation placeholders are required for execution. Steps include exact files, commands, expected results, and representative code snippets.
- Type/name consistency: token names use the `--session-*` pattern from the existing app and add only `--session-accent` / `--session-accent-strong`. Test IDs preserve existing IDs where known and add new Home IDs explicitly.
