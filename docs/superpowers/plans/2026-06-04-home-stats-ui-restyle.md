# Home and Stats UI Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle Home and Stats so they visually match the warm-paper Session/Workouts direction while preserving current content, behavior, routes, and data flow.

**Architecture:** Extend the existing session token surface to Home and Stats through `Layouts.app`, then restyle each page in place. Keep LiveView state, events, component boundaries, IDs, and test selectors stable; visual changes are expressed through Tailwind classes and existing CSS variables.

**Tech Stack:** Phoenix LiveView 1.1, HEEx templates, Tailwind CSS v4, Geist font, jj version control, ExUnit/Phoenix LiveViewTest.

---

## File Map

- Modify `lib/burpee_trainer_web/components/layouts.ex`
  - Treat `:home` and `:stats` as session-surface pages alongside `:workouts`.
  - Reuse the session-colored desktop and mobile nav treatment.
  - Preserve current nav routes, icons, labels, and mobile spacer behavior.

- Modify `test/burpee_trainer_web/components/layouts_test.exs`
  - Add tests for session-surface shell behavior on Home/Stats/Workouts and non-session behavior elsewhere.

- Modify `lib/burpee_trainer_web/live/overview_live.ex`
  - Restyle Home only; preserve assign functions, events, component names, IDs, and content order.

- Modify `test/burpee_trainer_web/controllers/page_controller_test.exs`
  - Add low-fragility assertions for Home session-surface styling and preserved ordering/selectors.

- Modify `lib/burpee_trainer_web/live/stats_live.ex`
  - Restyle helper components in the Stats LiveView: at-risk banner, streak card, goals, trends, recent sessions, buttons, and modal surfaces.

- Modify `lib/burpee_trainer_web/live/stats_live/render.html.heex`
  - Restyle the Stats page wrapper, FAB, and modal shells.

- Modify stats chart partials only if their surfaces still use old dark-dashboard tokens:
  - `lib/burpee_trainer_web/live/stats_live/progress_chart_template.html.heex`
  - `lib/burpee_trainer_web/live/stats_live/weekly_minutes_chart_template.html.heex`

- Modify `test/burpee_trainer_web/live/stats_live_test.exs`
  - Add structural assertions that Stats adopts session-surface styling without changing behavior.

---

## Task 1: Extend Session Surface Layout to Home and Stats

**Files:**

- Modify: `lib/burpee_trainer_web/components/layouts.ex`
- Modify: `test/burpee_trainer_web/components/layouts_test.exs`

- [ ] **Step 1: Add layout component tests for page shell variants**

Append these tests to `test/burpee_trainer_web/components/layouts_test.exs`:

```elixir
  describe "app layout session surface pages" do
    test "home, workouts, and stats use session surface chrome" do
      for page <- [:home, :workouts, :stats] do
        html =
          render_to_string(BurpeeTrainerWeb.Layouts, "app", "html",
            flash: %{},
            current_user: %{id: 1},
            current_page: page,
            current_level: nil,
            inner_block: []
          )

        assert html =~ "session-surface"
        assert html =~ "bg-[var(--session-bg)]"
        assert html =~ "text-[var(--session-ink)]"
        refute html =~ "bg-base-nav"
      end
    end

    test "non-session pages keep existing centered dark shell" do
      html =
        render_to_string(BurpeeTrainerWeb.Layouts, "app", "html",
          flash: %{},
          current_user: %{id: 1},
          current_page: :tracking_test,
          current_level: nil,
          inner_block: []
        )

      assert html =~ "bg-base-nav"
      assert html =~ "mx-auto max-w-2xl"
    end
  end
```

- [ ] **Step 2: Run layout tests and verify the new test fails**

Run:

```bash
mix test test/burpee_trainer_web/components/layouts_test.exs
```

Expected: FAIL because `:home` and `:stats` do not yet use session-surface nav/main/spacer classes.

- [ ] **Step 3: Implement a page helper in `layouts.ex`**

Add this helper near the existing private nav helpers:

```elixir
  defp session_surface_page?(:home), do: true
  defp session_surface_page?(:workouts), do: true
  defp session_surface_page?(:stats), do: true
  defp session_surface_page?(_page), do: false
```

Then assign it at the start of `app/1`:

```elixir
  def app(assigns) do
    assigns = assign(assigns, :session_surface_page?, session_surface_page?(assigns.current_page))

    ~H"""
```

Replace direct `@current_page == :workouts` layout checks with `@session_surface_page?` for:

- desktop nav session-surface classes
- mobile nav session-surface classes
- `session_nav?` passed to `nav_icon` and `bottom_tab`
- main session surface classes
- bottom spacer session surface classes

Keep Workouts-specific behavior only where truly page-specific; for this task the shell should be shared by Home, Workouts, and Stats.

- [ ] **Step 4: Run layout tests and verify pass**

Run:

```bash
mix test test/burpee_trainer_web/components/layouts_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit layout shell change**

Run:

```bash
jj describe -m "style(layout): share session surface shell"
jj new
```

---

## Task 2: Restyle Home Page

**Files:**

- Modify: `lib/burpee_trainer_web/live/overview_live.ex`
- Modify: `test/burpee_trainer_web/controllers/page_controller_test.exs`

- [ ] **Step 1: Add Home visual-structure assertions**

Add this test to `test/burpee_trainer_web/controllers/page_controller_test.exs`:

```elixir
  test "GET / uses session surface visual system", %{conn: conn} do
    user = user_fixture(%{"username" => "home_surface_user"})
    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ "session-surface"
    assert html =~ "text-[var(--session-ink)]"
    assert html =~ ~s(id="home-workout-card")
    assert html =~ ~s(id="home-week-rhythm")
  end
```

This test should pass after Task 1 because the layout supplies the surface. It protects against regressing the shell while Home is restyled.

- [ ] **Step 2: Run Home tests before changes**

Run:

```bash
mix test test/burpee_trainer_web/controllers/page_controller_test.exs
```

Expected: PASS after Task 1.

- [ ] **Step 3: Restyle the Home page wrapper and at-risk banner**

In `overview_live.ex`, change the main page container from dark-dashboard spacing to warm-paper spacing:

```heex
<div class="mx-auto max-w-lg space-y-7 pb-20 text-[var(--session-ink)]">
```

Restyle the at-risk banner to use session tokens and keep its existing text:

```heex
<div
  :if={@level_status.at_risk?}
  class="border border-[var(--session-border)] bg-[var(--session-track)]/40 px-4 py-3 flex items-start gap-3"
>
  <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-[var(--session-ink)]" />
  <p class="text-sm text-[var(--session-muted)]">
    <span class="font-semibold text-[var(--session-ink)]">
      Level {level_label(@level_status.level)} expires in {@level_status.days_left}d
    </span>
    — train both burpee types this week to keep it.
  </p>
</div>
```

- [ ] **Step 4: Restyle `status_strip/1`**

Keep all calculations and IDs. Update classes to warm-paper tokens:

- wrapper: `space-y-3 border-b border-[var(--session-border)] px-1 pb-5`
- large minutes: `text-5xl font-semibold leading-none tracking-[-0.04em] tabular-nums text-[var(--session-ink)]`
- goal text: `text-sm text-[var(--session-muted)]`
- metadata: `text-xs text-[var(--session-muted)] tabular-nums`
- progress track: `h-1 w-full bg-[var(--session-track)]`
- progress fill: `h-1 bg-[var(--session-ink)] transition-all duration-500`
- weekly rhythm trained segment: `bg-[var(--session-ink)]`
- today segment: `bg-[var(--session-muted)]`
- empty segment: `bg-[var(--session-track)]`
- rhythm labels use session muted/ink instead of `base-content` and `primary`.

Do not rename `id="home-week-rhythm"` or `data-week-rhythm-segment`.

- [ ] **Step 5: Restyle `workout_card/1` empty state**

Keep `id="home-workout-card"` and links. Convert the empty state to a quiet bordered panel:

```heex
<div id="home-workout-card" class="border border-[var(--session-border)] bg-[var(--session-bg)] px-5 py-5 space-y-5">
```

Use:

- heading: `text-xl font-semibold leading-snug tracking-[-0.02em] text-[var(--session-ink)]`
- subtext: `text-sm text-[var(--session-muted)]`
- create button: `size-12 border border-[var(--session-ink)] text-[var(--session-ink)] hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition`
- browse link: `text-sm text-[var(--session-muted)] hover:text-[var(--session-ink)] transition`

- [ ] **Step 6: Restyle populated `workout_card/1`**

Keep the same data and start route. Make it a training-row/card inspired by the mock:

- card: `border border-[var(--session-border)] bg-[var(--session-bg)] px-5 py-4`
- name: `text-base font-semibold leading-snug truncate text-[var(--session-ink)]`
- metadata: `text-sm text-[var(--session-muted)] tabular-nums`
- play button: `size-11 shrink-0 border border-[var(--session-ink)] text-[var(--session-ink)] flex items-center justify-center hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition`
- divider: `border-t border-[var(--session-border)]`
- pick another link: `text-xs text-[var(--session-muted)] hover:text-[var(--session-ink)] transition`

- [ ] **Step 7: Restyle `coach_suggestion/1` and log link**

Keep `data-home-coach-suggestion` and destination. Use low-noise row styling:

- suggestion row: `border border-[var(--session-border)] bg-[var(--session-track)]/25 px-4 py-3 flex items-center gap-3`
- label: `text-xs text-[var(--session-muted)] font-medium uppercase tracking-[0.12em]`
- dimension: `text-xs font-semibold text-[var(--session-ink)]`
- rationale: `text-xs text-[var(--session-muted)] truncate`
- action link: `shrink-0 text-sm text-[var(--session-ink)] hover:text-[var(--session-muted)] transition font-medium whitespace-nowrap`
- log link: `text-sm text-[var(--session-muted)] hover:text-[var(--session-ink)] transition`

- [ ] **Step 8: Restyle Home log modal shell**

Keep modal IDs and component wiring. Change modal sheet to session surface:

```heex
class="session-surface relative z-10 w-full sm:max-w-md max-h-[calc(100dvh-1rem)] sm:max-h-[calc(100dvh-3rem)] overflow-y-auto bg-[var(--session-bg)] text-[var(--session-ink)] border border-[var(--session-border)] rounded-t-2xl sm:rounded-2xl p-5 sm:p-6"
```

No inline scripts or component changes.

- [ ] **Step 9: Run Home tests**

Run:

```bash
mix test test/burpee_trainer_web/controllers/page_controller_test.exs
```

Expected: PASS.

- [ ] **Step 10: Commit Home restyle**

Run:

```bash
jj describe -m "style(home): use session surface design"
jj new
```

---

## Task 3: Restyle Stats Page Shell and Top Sections

**Files:**

- Modify: `lib/burpee_trainer_web/live/stats_live/render.html.heex`
- Modify: `lib/burpee_trainer_web/live/stats_live.ex`
- Modify: `test/burpee_trainer_web/live/stats_live_test.exs`

- [ ] **Step 1: Add Stats visual-structure assertions**

Add this test inside `describe "/stats"` in `test/burpee_trainer_web/live/stats_live_test.exs`:

```elixir
    test "uses session surface visual system", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stats")

      assert has_element?(view, "[data-stats-page].session-surface")
      assert has_element?(view, "#stats-log-button")
      assert render(view) =~ "text-[var(--session-ink)]"
    end
```

- [ ] **Step 2: Run the focused Stats test and verify failure**

Run:

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs --only test:"uses session surface visual system"
```

Expected: FAIL because `data-stats-page` and `#stats-log-button` are not yet present.

- [ ] **Step 3: Restyle `render.html.heex` shell and FAB**

Change the top wrapper to:

```heex
<div data-stats-page class="session-surface mx-auto max-w-lg space-y-6 pb-24 text-[var(--session-ink)]">
```

Update the FAB button to keep `phx-click="open_log_modal"` and add `id="stats-log-button"`:

```heex
<button
  id="stats-log-button"
  type="button"
  phx-click="open_log_modal"
  class="size-12 border border-[var(--session-ink)] bg-[var(--session-bg)] text-[var(--session-ink)] flex items-center justify-center hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition"
  aria-label="Log session"
>
```

Update log and goal modal sheets to use `session-surface bg-[var(--session-bg)] text-[var(--session-ink)] border-[var(--session-border)]` and remove `shadow-2xl`.

- [ ] **Step 4: Restyle `at_risk_banner/1` and `streak_card/1`**

Keep all content and logic. Update classes:

- at-risk banner: border/session-track panel matching Home.
- streak card wrapper: `border border-[var(--session-border)] bg-[var(--session-bg)] px-5 py-5 space-y-5`
- large weekly minutes: `text-7xl font-semibold tracking-[-0.05em] text-[var(--session-ink)]`
- `/ 80 min`, streak text, and level labels: session muted tokens.
- progress track/fill: session track and session ink, with lower opacity only for off-pace states.
- week-day markers: session ink for active, session muted for today outline, session track for inactive.
- push-up row divider: session border; push-up value uses session ink, not hardcoded blue unless data emphasis is necessary.

- [ ] **Step 5: Run focused Stats tests**

Run:

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs --only test:"uses session surface visual system"
mix test test/burpee_trainer_web/live/stats_live_test.exs --only test:"FAB opens log modal"
```

Expected: PASS.

- [ ] **Step 6: Commit Stats shell/top restyle**

Run:

```bash
jj describe -m "style(stats): use session surface shell"
jj new
```

---

## Task 4: Restyle Stats Goals, Trends, and Sessions

**Files:**

- Modify: `lib/burpee_trainer_web/live/stats_live.ex`
- Modify if needed: `lib/burpee_trainer_web/live/stats_live/progress_chart_template.html.heex`
- Modify if needed: `lib/burpee_trainer_web/live/stats_live/weekly_minutes_chart_template.html.heex`
- Modify: `test/burpee_trainer_web/live/stats_live_test.exs`

- [ ] **Step 1: Run existing Stats tests before restyle**

Run:

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs
```

Expected: PASS after Task 3.

- [ ] **Step 2: Restyle goals section**

In `stats_live.ex`, update goals components while preserving text, buttons, `phx-click`, `phx-value-type`, and modal behavior:

- section wrapper: `space-y-3`
- section label: uppercase/small session muted text
- goal slots: `border border-[var(--session-border)] bg-[var(--session-bg)] px-4 py-4`
- type labels: `text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]`
- target numbers: `text-2xl font-semibold tracking-[-0.03em] text-[var(--session-ink)]`
- empty state text/buttons: muted text with ink action buttons.
- progress tracks: session track; fills use session ink unless existing data-series distinction is required.

- [ ] **Step 3: Restyle trends/charts section**

Preserve chart hooks/templates and data. Update surrounding surfaces:

- chart section/card wrappers use session borders/background.
- labels use session muted and ink.
- filter/range controls use the same quiet segmented style as Workouts filters: border/session-bg, active ink/background inversion, inactive muted.
- Chart SVG/canvas colors should not hardcode dark-dashboard colors; use existing chart code if it already respects CSS/current colors, otherwise change template stroke/fill tokens to session variables.

- [ ] **Step 4: Restyle recent sessions section**

Preserve clickable tracked-session links, timed-session non-clickability, `Load more`, and all existing labels. Update rows:

- section wrapper: `space-y-3`
- row/card: `border-b border-[var(--session-border)] py-4 last:border-b-0`
- primary plan/type text: session ink
- date/meta text: session muted
- counts/duration: tabular, session ink/muted hierarchy
- Tracked/consistency badge: restrained border/session-track badge, not bright dashboard chip.
- Load more button: border ink/session-bg with hover inverted state.

- [ ] **Step 5: Run Stats behavior tests**

Run:

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs
```

Expected: PASS. Existing assertions for goals, recent sessions, tracking links, load more, log modal, and goal modal must remain valid.

- [ ] **Step 6: Commit Stats content restyle**

Run:

```bash
jj describe -m "style(stats): restyle performance sections"
jj new
```

---

## Task 5: Final Verification and Push

**Files:**

- No planned edits unless verification finds issues.

- [ ] **Step 1: Run focused page tests**

Run:

```bash
mix test test/burpee_trainer_web/controllers/page_controller_test.exs test/burpee_trainer_web/live/stats_live_test.exs test/burpee_trainer_web/components/layouts_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run full precommit**

Run:

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 3: Manual visual QA**

Check in browser:

- `/` light mode: warm-paper background, current order preserved, workout card before coach suggestions.
- `/` dark/system-dark mode: session tokens invert correctly.
- `/stats` light mode: all existing sections present, no dark-dashboard cards remain.
- `/stats` dark/system-dark mode: readable cards/charts/rows.
- Mobile width: bottom nav spacing, Home action card, Stats recent-session rows, FAB position.

- [ ] **Step 4: Push to master if requested**

If the user wants direct master push, run:

```bash
jj bookmark set master -r @-
jj git push -b master
```

If the user wants a review branch instead, create/push a bookmark:

```bash
jj bookmark create home-stats-ui-restyle -r @-
jj git push -b home-stats-ui-restyle
```

---

## Self-Review

Spec coverage:

- Warm-paper/black-ink Session visual direction: Tasks 1-4.
- Preserve Home order and current content: Task 2 explicitly keeps IDs/order and current components.
- Preserve Stats sections and behavior: Tasks 3-4 keep all existing events and tests.
- Light/dark/system-dark: Task 1 reuses session shell; Task 5 manual QA covers modes.
- No new features/data changes: all tasks are class/template restyles and test assertions.

Placeholder scan:

- No `TBD`, `TODO`, or undefined future behavior.
- Each code-changing task names exact files and concrete class/token replacements.

Type/name consistency:

- New helper name is consistently `session_surface_page?/1`.
- New test selectors are consistently `data-stats-page` and `#stats-log-button`.
