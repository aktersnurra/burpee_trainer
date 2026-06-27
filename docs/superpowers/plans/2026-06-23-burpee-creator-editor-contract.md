# Burpee Creator/Editor Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `/workouts/new` and `/workouts/:id/edit` into an intent-first, contract-first workout creator/editor that hides solver mechanics by default and keeps the current app colors.

**Architecture:** Add a small pure presentation boundary for workout contract data, then use LiveView phase state to move the UI from intent → review → readable editor → focused block sheet. Keep the existing solver and persistence flow; only add behavior needed for disclosure, selected block editing, locked-block copy, and product conflict states.

**Tech Stack:** Phoenix LiveView, HEEx embedded templates, Tailwind v4 utilities, existing `--session-*` CSS tokens, ExUnit, Phoenix.LiveViewTest, jj.

## Global Constraints

- Keep the current app color palette; do not introduce the cool-neutral palette from the original design input in this pass.
- Creator/editor only; do not redesign Home/overview, Stats, Videos, or the live Session screen.
- Default UI must be readable before editable: no block/set spreadsheet, prescription graph, raw solver/debug data, reps/sec, or technical cadence copy by default.
- Use consistent nouns in touched creator/editor copy: Workout, Block, Set, Rest.
- One primary CTA per surface; secondary actions are ghost/outline/text.
- Destructive actions use existing muted destructive styling and are never primary.
- Use real button/link elements for tappable UI and include pressed/disabled/loading/invalid states where relevant.
- Follow TDD: write failing tests first, verify they fail for the expected reason, implement minimal code, verify green.
- Finish with `mix format` and `mix precommit`.

---

## File Structure

- Create: `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex`
  - Pure functions that convert `%WorkoutPlan{}` + derived summary into contract cards, structure-map marks, grouped structure preview, and readable block rows.
- Create: `test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs`
  - Fast unit tests for contract copy, block-row copy, grouped preview, and map marks.
- Modify: `lib/burpee_trainer/plan_editor/state.ex`
  - Add UI state for `selected_block_index`, `locked_block_indexes`, and creator contract phase.
- Modify: `lib/burpee_trainer/plan_editor/input.ex`
  - Add creator intent/difficulty state only if the UI needs a normalized source of truth. Do not persist these fields to `WorkoutPlan` in this pass.
- Modify: `lib/burpee_trainer/plan_editor.ex`
  - Add pure transitions for selecting/closing a block, locking/unlocking blocks, and rebalancing unlocked blocks.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
  - Wire LiveView events and assigns to the new phase/disclosure/block-sheet behavior.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
  - Replace peer Type/Target/Style/default prescription surfaces with the phase-based creator/editor shell.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
  - Convert this to the contract review/editor overview host; hide graph/debug mechanics behind Advanced constraints.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex`
  - Either retire from default rendering or restrict it to advanced/manual detail mode only.
- Create: embedded templates under `lib/burpee_trainer_web/live/plans_live/edit/`:
  - `creator_intent_template.html.heex`
  - `workout_contract_template.html.heex`
  - `workout_editor_overview_template.html.heex`
  - `block_sheet_template.html.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`
  - Update LiveView tests to assert the new contract-first UI and preserve existing solver/save behavior.
- Modify: `assets/css/app.css`
  - Only add tiny interaction utilities if Tailwind classes are insufficient. Do not change palette tokens.

---

### Task 1: Presentation Boundary for Workout Contract Data

**Files:**

- Create: `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex`
- Create: `test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs`

**Interfaces:**

- Consumes: `%BurpeeTrainer.Workouts.WorkoutPlan{}`, derived summary map (`%{duration_sec:, burpee_count:, both_ok:}`), existing `BurpeeTrainerWeb.Fmt.duration_sec/1`.
- Produces:
  - `BurpeeTrainerWeb.PlansLive.Edit.Presentation.contract(plan, derived) :: map()`
  - `BurpeeTrainerWeb.PlansLive.Edit.Presentation.block_rows(plan, locked_indexes \\ MapSet.new()) :: [map()]`
  - `BurpeeTrainerWeb.PlansLive.Edit.Presentation.structure_map(rows) :: [map()]`
  - `BurpeeTrainerWeb.PlansLive.Edit.Presentation.structure_groups(rows) :: [map()]`

- [ ] **Step 1: Write the failing presentation tests**

Create `test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs`:

```elixir
defmodule BurpeeTrainerWeb.PlansLive.Edit.PresentationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
  alias BurpeeTrainerWeb.PlansLive.Edit.Presentation

  defp set(position, reps, sec_per_rep, rest) do
    %Set{
      position: position,
      burpee_count: reps,
      sec_per_rep: sec_per_rep,
      sec_per_burpee: sec_per_rep,
      end_of_set_rest: rest
    }
  end

  defp plan do
    %WorkoutPlan{
      name: "Contract plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 45,
      pacing_style: :unbroken,
      blocks: [
        %Block{position: 1, repeat_count: 3, sets: [set(1, 15, 3.8, 38)]}
      ]
    }
  end

  test "contract summarizes duration, type, reps, blocks, and feel" do
    contract = Presentation.contract(plan(), %{duration_sec: 1_200, burpee_count: 45})

    assert contract.title == "20 min Six-count"
    assert contract.stats == "45 reps · 3 blocks"
    assert contract.structure == "Mostly unbroken, rests increase gradually"
    assert contract.feel == "Expected feel: controlled, not all-out"
  end

  test "block rows expand repeated blocks into readable rows" do
    rows = Presentation.block_rows(plan())

    assert length(rows) == 3
    assert Enum.at(rows, 0).title == "Block 1"
    assert Enum.at(rows, 0).headline == "Unbroken · 15 reps"
    assert Enum.at(rows, 0).detail == "Rep every 3.8s · 0:38 rest"
    assert Enum.at(rows, 2).title == "Block 3"
  end

  test "locked indexes are exposed as Locked by you" do
    [first | _] = Presentation.block_rows(plan(), MapSet.new([0]))

    assert first.locked? == true
    assert first.lock_label == "Locked by you"
  end

  test "structure map marks expose height, gap, and label" do
    rows = Presentation.block_rows(plan())
    marks = Presentation.structure_map(rows)

    assert length(marks) == 3
    assert hd(marks).label == "Block 1 · 15 reps"
    assert is_integer(hd(marks).height)
    assert is_integer(hd(marks).gap)
  end

  test "structure groups compact adjacent similar block rows" do
    rows = Presentation.block_rows(plan())

    assert [%{range: "1–3", label: "15 reps · 0:38 rest"}] =
             Presentation.structure_groups(rows)
  end
end
```

- [ ] **Step 2: Run the presentation tests and verify RED**

Run:

```bash
cd /Users/aktersnurra/projects/vibe/burpee_trainer.workspaces/ui-ux-refactor
mix test test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs
```

Expected: FAIL because `BurpeeTrainerWeb.PlansLive.Edit.Presentation` does not exist.

- [ ] **Step 3: Add the pure presentation module**

Create `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex`:

```elixir
defmodule BurpeeTrainerWeb.PlansLive.Edit.Presentation do
  @moduledoc """
  Presentation-only summaries for the plan creator/editor.

  This module keeps wording, block-row expansion, and structure-map data out
  of the LiveView process. It does not change solver behavior or persistence.
  """

  alias BurpeeTrainer.Workouts.{Block, WorkoutPlan}
  alias BurpeeTrainerWeb.Fmt

  @type block_row :: %{
          index: non_neg_integer(),
          source_block_index: non_neg_integer(),
          title: String.t(),
          headline: String.t(),
          detail: String.t(),
          reps: non_neg_integer(),
          sec_per_rep: number() | nil,
          rest_sec: non_neg_integer(),
          locked?: boolean(),
          lock_label: String.t() | nil
        }

  @spec contract(WorkoutPlan.t(), map() | nil) :: map()
  def contract(%WorkoutPlan{} = plan, derived \\ nil) do
    rows = block_rows(plan)
    total_reps = derived_value(derived, :burpee_count) || Enum.sum(Enum.map(rows, & &1.reps))
    duration_min = plan.target_duration_min || duration_min_from_derived(derived)

    %{
      title: "#{duration_min} min #{type_label(plan.burpee_type)}",
      stats: "#{total_reps} reps · #{length(rows)} #{plural(length(rows), "block")}",
      structure: structure_sentence(plan, rows),
      feel: expected_feel(plan),
      block_rows: rows,
      structure_map: structure_map(rows),
      structure_groups: structure_groups(rows)
    }
  end

  @spec block_rows(WorkoutPlan.t(), MapSet.t()) :: [block_row()]
  def block_rows(%WorkoutPlan{blocks: blocks}, locked_indexes \\ MapSet.new()) when is_list(blocks) do
    blocks
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, source_index} -> expand_block(block, source_index) end)
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      locked? = MapSet.member?(locked_indexes, index) || MapSet.member?(locked_indexes, row.source_block_index)

      row
      |> Map.put(:index, index)
      |> Map.put(:title, "Block #{index + 1}")
      |> Map.put(:locked?, locked?)
      |> Map.put(:lock_label, if(locked?, do: "Locked by you", else: nil))
    end)
  end

  def block_rows(_plan, _locked_indexes), do: []

  @spec structure_map([block_row()]) :: [map()]
  def structure_map(rows) do
    max_reps = rows |> Enum.map(& &1.reps) |> Enum.max(fn -> 1 end)

    Enum.map(rows, fn row ->
      %{
        label: "#{row.title} · #{row.reps} reps",
        height: max(24, round(row.reps / max(max_reps, 1) * 48)),
        gap: rest_gap(row.rest_sec),
        shade: shade(row.reps, max_reps)
      }
    end)
  end

  @spec structure_groups([block_row()]) :: [map()]
  def structure_groups(rows) do
    rows
    |> Enum.chunk_by(fn row -> {row.reps, rest_bucket(row.rest_sec)} end)
    |> Enum.map(fn chunk ->
      first = hd(chunk)
      last = List.last(chunk)

      %{
        range: range_label(first.index + 1, last.index + 1),
        label: "#{first.reps} reps · #{Fmt.duration_sec(first.rest_sec)} rest"
      }
    end)
  end

  defp expand_block(%Block{} = block, source_index) do
    repeat_count = max(block.repeat_count || 1, 1)
    reps = block_reps(block)
    sec_per_rep = representative_sec_per_rep(block)
    rest_sec = block_rest_sec(block)

    for _repeat <- 1..repeat_count do
      %{
        source_block_index: source_index,
        headline: "Unbroken · #{reps} reps",
        detail: "Rep every #{format_sec_per_rep(sec_per_rep)} · #{Fmt.duration_sec(rest_sec)} rest",
        reps: reps,
        sec_per_rep: sec_per_rep,
        rest_sec: rest_sec
      }
    end
  end

  defp block_reps(%Block{sets: sets}) when is_list(sets) do
    sets |> Enum.map(&(&1.burpee_count || 0)) |> Enum.sum()
  end

  defp block_reps(_block), do: 0

  defp representative_sec_per_rep(%Block{sets: sets}) when is_list(sets) do
    sets
    |> Enum.sort_by(&(&1.position || 0))
    |> List.first()
    |> case do
      %{sec_per_rep: sec_per_rep} when is_number(sec_per_rep) -> sec_per_rep
      _ -> nil
    end
  end

  defp representative_sec_per_rep(_block), do: nil

  defp block_rest_sec(%Block{sets: sets}) when is_list(sets) do
    sets
    |> Enum.sort_by(&(&1.position || 0))
    |> List.last()
    |> case do
      %{end_of_set_rest: rest} when is_number(rest) -> round(rest)
      _ -> 0
    end
  end

  defp block_rest_sec(_block), do: 0

  defp type_label(:six_count), do: "Six-count"
  defp type_label(:navy_seal), do: "Navy SEAL"
  defp type_label(other), do: Fmt.burpee_type(other)

  defp derived_value(nil, _key), do: nil
  defp derived_value(map, key) when is_map(map), do: Map.get(map, key)

  defp duration_min_from_derived(%{duration_sec: seconds}) when is_number(seconds), do: round(seconds / 60)
  defp duration_min_from_derived(_derived), do: 20

  defp structure_sentence(%WorkoutPlan{pacing_style: :unbroken}, _rows),
    do: "Mostly unbroken, rests increase gradually"

  defp structure_sentence(_plan, rows) when length(rows) > 1,
    do: "Steady blocks with planned rest"

  defp structure_sentence(_plan, _rows), do: "Simple steady structure"

  defp expected_feel(%WorkoutPlan{pacing_style: :unbroken}),
    do: "Expected feel: controlled, not all-out"

  defp expected_feel(_plan), do: "Expected feel: steady and repeatable"

  defp format_sec_per_rep(nil), do: "—"
  defp format_sec_per_rep(value) when is_number(value), do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}s"

  defp rest_gap(rest_sec) when rest_sec <= 0, do: 4
  defp rest_gap(rest_sec) when rest_sec < 30, do: 8
  defp rest_gap(rest_sec) when rest_sec < 60, do: 12
  defp rest_gap(_rest_sec), do: 16

  defp rest_bucket(rest_sec) when rest_sec < 30, do: :short
  defp rest_bucket(rest_sec) when rest_sec < 60, do: :medium
  defp rest_bucket(_rest_sec), do: :long

  defp shade(reps, max_reps) when max_reps <= 0 or reps <= 0, do: 0.35
  defp shade(reps, max_reps), do: Float.round(0.35 + reps / max_reps * 0.5, 2)

  defp range_label(from, from), do: Integer.to_string(from)
  defp range_label(from, to), do: "#{from}–#{to}"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
```

- [ ] **Step 4: Run the presentation tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit the presentation boundary**

Run:

```bash
jj describe -m "feat(ui): add workout contract presentation helpers"
jj new
```

---

### Task 2: Intent-First Creator Shell and Advanced Disclosure

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
- Create: `lib/burpee_trainer_web/live/plans_live/edit/creator_intent_template.html.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`

**Interfaces:**

- Consumes: existing `PlanEditor.change_basics/2`, `PlanEditor.pick_type/2`, `PlanEditor.pick_pacing/2`, existing generated solver state.
- Produces:
  - LiveView assigns: `:creator_phase`, `:creator_advanced?`, `:creator_intent`, `:creator_difficulty`.
  - LiveView events: `toggle_advanced_constraints`, `pick_creator_intent`, `set_creator_difficulty`, `generate_workout`, `edit_generated_workout`.
  - `creator_intent_template(assigns)` embedded template.

- [ ] **Step 1: Write the failing creator-shell tests**

In `test/burpee_trainer_web/live/workouts_live_test.exs`, replace the existing `"renders the new plan editor surface"` assertions with this new test and keep the old save/solver tests in place for later updates:

```elixir
test "new workout opens as an intent-first creator, not a solver panel", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/workouts/new")

  assert has_element?(view, "#creator-intent-screen")
  assert html =~ "Create workout"
  assert html =~ "What are we doing?"
  assert html =~ "Six-count"
  assert html =~ "Navy SEAL"
  assert html =~ "20 min"
  assert html =~ "30 min"
  assert html =~ "Planned session"
  assert html =~ "Catch up"
  assert html =~ "Easy technique"
  assert html =~ "Max reps"
  assert html =~ "Difficulty"
  assert html =~ "Generate workout"

  refute html =~ "Block pattern"
  refute html =~ "Prescription graph"
  refute html =~ "Solver computes"
  refute html =~ ">Pace<"
end

test "advanced constraints are collapsed until requested", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/workouts/new")

  assert has_element?(view, "#advanced-constraints-toggle")
  refute html =~ ~s(id="advanced-constraints-panel")

  view |> element("#advanced-constraints-toggle") |> render_click()

  assert has_element?(view, "#advanced-constraints-panel")
  html = render(view)
  assert html =~ "Manual target reps"
  assert html =~ "Unbroken cap"
  assert html =~ "Minimum rest"
  assert html =~ "Maximum pace"
  assert html =~ "Solver strictness"
end
```

- [ ] **Step 2: Run the creator-shell tests and verify RED**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: FAIL because `#creator-intent-screen` is not rendered.

Then run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: FAIL because `#advanced-constraints-toggle` does not exist.

- [ ] **Step 3: Add LiveView phase and disclosure assigns/events**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`, update `mount/3` initial assigns:

```elixir
|> assign(:creator_phase, if(socket.assigns.live_action == :new, do: :intent, else: :editor))
|> assign(:creator_advanced?, false)
|> assign(:creator_intent, :planned_session)
|> assign(:creator_difficulty, 3)
```

Add these event handlers near the Layer 1 event handlers:

```elixir
def handle_event("toggle_advanced_constraints", _params, socket) do
  {:noreply, update(socket, :creator_advanced?, &(!&1))}
end

def handle_event("pick_creator_intent", %{"intent" => intent}, socket) do
  intent =
    case intent do
      "catch_up" -> :catch_up
      "easy_technique" -> :easy_technique
      "max_reps" -> :max_reps
      _ -> :planned_session
    end

  {:noreply, assign(socket, :creator_intent, intent)}
end

def handle_event("set_creator_difficulty", %{"difficulty" => difficulty}, socket) do
  difficulty =
    case Integer.parse(to_string(difficulty || "")) do
      {value, ""} when value in 1..5 -> value
      _ -> socket.assigns.creator_difficulty
    end

  {:noreply, assign(socket, :creator_difficulty, difficulty)}
end

def handle_event("generate_workout", _params, socket) do
  {:noreply, assign(socket, :creator_phase, :review)}
end

def handle_event("edit_generated_workout", _params, socket) do
  {:noreply, assign(socket, :creator_phase, :editor)}
end
```

- [ ] **Step 4: Add the creator intent template**

Create `lib/burpee_trainer_web/live/plans_live/edit/creator_intent_template.html.heex`:

```heex
<section id="creator-intent-screen" class="space-y-5">
  <.qs_surface class="bg-[var(--session-surface)]/55 p-5">
    <div class="space-y-2">
      <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
        Create workout
      </p>
      <h1 class="text-2xl font-semibold tracking-[-0.04em] text-[var(--session-ink)]">
        What are we doing?
      </h1>
      <p class="text-sm leading-6 text-[var(--session-muted)]">
        Set the training intent first. The generated workout stays editable after review.
      </p>
    </div>
  </.qs_surface>

  <.qs_surface class="overflow-hidden bg-[var(--session-surface)]/50">
    <div class="border-b border-[var(--session-border)] px-5 py-4">
      <p class="text-sm font-semibold text-[var(--session-ink)]">Burpee type</p>
      <p class="mt-1 text-xs text-[var(--session-muted)]">Choose the movement pattern.</p>
    </div>
    <.plan_type_picker plan_input={@plan_input} />
  </.qs_surface>

  <.qs_surface class="overflow-hidden bg-[var(--session-surface)]/50">
    <form id="creator-duration-form" phx-change="change_basics" class="p-5">
      <p class="text-sm font-semibold text-[var(--session-ink)]">Duration</p>
      <div class="mt-3 grid grid-cols-3 gap-2">
        <button type="button" phx-click="change_basics" phx-value-target_duration_min="20" class="rounded-lg border border-[var(--session-border)] px-3 py-3 text-sm font-medium text-[var(--session-ink)] active:bg-[var(--session-track)]/70">20 min</button>
        <button type="button" phx-click="change_basics" phx-value-target_duration_min="30" class="rounded-lg border border-[var(--session-border)] px-3 py-3 text-sm font-medium text-[var(--session-ink)] active:bg-[var(--session-track)]/70">30 min</button>
        <label class="rounded-lg border border-[var(--session-border)] px-3 py-2 text-sm text-[var(--session-muted)]">
          Custom
          <input type="number" name="target_duration_min" min="1" max="120" value={@plan_input.target_duration_min} class="mt-1 w-full bg-transparent text-sm tabular-nums text-[var(--session-ink)] focus:outline-none" />
        </label>
      </div>
    </form>
  </.qs_surface>

  <.qs_surface class="bg-[var(--session-surface)]/50 p-5">
    <p class="text-sm font-semibold text-[var(--session-ink)]">Intent</p>
    <div class="mt-3 grid grid-cols-2 gap-2">
      <%= for {label, value} <- [{"Planned session", "planned_session"}, {"Catch up", "catch_up"}, {"Easy technique", "easy_technique"}, {"Max reps", "max_reps"}] do %>
        <button
          type="button"
          phx-click="pick_creator_intent"
          phx-value-intent={value}
          class={[
            "rounded-lg border px-3 py-3 text-left text-sm font-medium transition active:bg-[var(--session-track)]/70",
            if(to_string(@creator_intent) == value,
              do: "border-[var(--session-toggle-border)] bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)]",
              else: "border-[var(--session-border)] text-[var(--session-ink)]"
            )
          ]}
        >
          {label}
        </button>
      <% end %>
    </div>
  </.qs_surface>

  <.qs_surface class="bg-[var(--session-surface)]/50 p-5">
    <form id="creator-difficulty-form" phx-change="set_creator_difficulty" class="space-y-3">
      <div class="flex items-center justify-between">
        <p class="text-sm font-semibold text-[var(--session-ink)]">Difficulty</p>
        <p class="text-sm tabular-nums text-[var(--session-muted)]">{@creator_difficulty} / 5</p>
      </div>
      <input type="range" name="difficulty" min="1" max="5" value={@creator_difficulty} class="w-full accent-[var(--session-ink)]" />
    </form>
  </.qs_surface>

  <.qs_surface class="bg-[var(--session-surface)]/50 p-5">
    <button
      id="advanced-constraints-toggle"
      type="button"
      phx-click="toggle_advanced_constraints"
      class="flex w-full items-center justify-between text-left text-sm font-medium text-[var(--session-ink)] active:text-[var(--session-muted)]"
    >
      <span>Advanced constraints</span>
      <span class="text-[var(--session-muted)]">{if @creator_advanced?, do: "Hide", else: "Show"}</span>
    </button>

    <div :if={@creator_advanced?} id="advanced-constraints-panel" class="mt-5 space-y-4 border-t border-[var(--session-border)] pt-5">
      <.plan_goal_controls plan_input={@plan_input} level={@level} />
      <.plan_pacing_controls plan_input={@plan_input} />
      <p class="text-xs leading-5 text-[var(--session-muted)]">Unbroken cap, minimum rest, maximum pace, and solver strictness use the current safe defaults in this pass.</p>
    </div>
  </.qs_surface>

  <button
    id="generate-workout"
    type="button"
    phx-click="generate_workout"
    disabled={not (@derived && @derived.both_ok)}
    class={[
      "w-full rounded-xl px-5 py-4 text-sm font-semibold transition active:translate-y-px",
      if(@derived && @derived.both_ok,
        do: "bg-[var(--session-ink)] text-[var(--session-bg)] phx-click-loading:opacity-60",
        else: "cursor-not-allowed border border-[var(--session-border)] bg-[var(--session-track)] text-[var(--session-muted)]"
      )
    ]}
  >
    Generate workout
  </button>
</section>
```

- [ ] **Step 5: Use the creator template from `render.html.heex`**

Replace the current peer Type/Target/Style surfaces in `render.html.heex` with a phase branch:

```heex
<%= if @live_action == :new and @creator_phase == :intent do %>
  <.creator_intent_template
    plan_input={@plan_input}
    level={@level}
    creator_intent={@creator_intent}
    creator_difficulty={@creator_difficulty}
    creator_advanced?={@creator_advanced?}
    derived={@derived}
  />
<% else %>
  <.plan_solution_card
    form={@form}
    expanded_blocks={@expanded_blocks}
    expanded_timeline_row={@expanded_timeline_row}
    open_block_menu={@open_block_menu}
    plan_input={@plan_input}
    manual_edit={@manual_edit}
    derived={@derived}
    solver_error={@solver_error}
    timeline_error={@timeline_error}
    solver_solution={@solver_solution}
    live_action={@live_action}
    level={@level}
    creator_phase={@creator_phase}
  />
<% end %>
```

Keep `<.plan_editor_header ...>` above the branch only if it still reads as a quiet name/edit header; otherwise move name editing into Advanced constraints during Task 3.

- [ ] **Step 6: Run the creator-shell tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: both PASS.

- [ ] **Step 7: Commit the creator shell**

Run:

```bash
jj describe -m "feat(ui): make workout creator intent first"
jj new
```

---

### Task 3: Generated Workout Review Contract

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Create: `lib/burpee_trainer_web/live/plans_live/edit/workout_contract_template.html.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`

**Interfaces:**

- Consumes: `Presentation.contract/2`, `@creator_phase`, existing save form.
- Produces:
  - `workout_contract_template(assigns)` embedded template.
  - Review phase with `#workout-contract-review`, `[data-structure-map]`, `#start-workout`, `#edit-workout`.
  - LiveView event `start_workout` that persists a new plan then navigates to `/session/:id`, or navigates directly for an existing plan.

- [ ] **Step 1: Write failing review tests**

Append these tests under `describe "/workouts/new"` in `test/burpee_trainer_web/live/workouts_live_test.exs`:

```elixir
test "generated review shows a readable workout contract before block data", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view |> element("#generate-workout") |> render_click()

  html = render(view)
  assert has_element?(view, "#workout-contract-review")
  assert html =~ "20 min Six-count"
  assert html =~ "reps ·"
  assert html =~ "blocks"
  assert html =~ "Expected feel:"
  assert has_element?(view, "[data-structure-map]")
  assert has_element?(view, "#start-workout")
  assert has_element?(view, "#edit-workout")

  refute html =~ "Block pattern"
  refute html =~ "Prescription graph"
  refute html =~ "Solver computes"
end```

- [ ] **Step 2: Run the review tests and verify RED**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: FAIL because review contract does not exist yet.

- [ ] **Step 3: Alias and assign presentation contract in the LiveView**

In `edit.ex`, add:

```elixir
alias BurpeeTrainerWeb.PlansLive.Edit.Presentation
```

In `plan_solution_card/1`, after `form_plan = ...`, assign the contract:

```elixir
contract = Presentation.contract(form_plan, assigns.derived)

assigns =
  assigns
  |> assign(:contract, contract)
  # keep existing assigns below
```

Add attr to `plan_solution_card`:

```elixir
attr(:creator_phase, :atom, default: :editor)
```

- [ ] **Step 4: Add `start_workout` event**

Add this event below `handle_event("save", ...)`:

```elixir
def handle_event("start_workout", params, socket) do
  if feasible_prescription?(socket.assigns.derived) do
    submitted_params = Map.get(params, "workout_plan", %{})
    form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    full_params =
      form_plan
      |> plan_to_attrs()
      |> Map.merge(merge_basics(submitted_params, socket.assigns.editor.input))

    start_plan(socket, socket.assigns.live_action, full_params)
  else
    {:noreply, assign(socket, :solver_error, "Fix workout before starting")}
  end
end
```

Add helpers near `save_plan/3`:

```elixir
defp start_plan(socket, :new, params) do
  case Workouts.create_plan(socket.assigns.current_user, params) do
    {:ok, plan} ->
      {:noreply,
       socket
       |> put_flash(:info, "Workout ready.")
       |> push_navigate(to: ~p"/session/#{plan.id}")}

    {:error, changeset} ->
      {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_derived()}
  end
end

defp start_plan(socket, :edit, params) do
  case Workouts.update_plan(socket.assigns.plan, params) do
    {:ok, plan} ->
      {:noreply,
       socket
       |> put_flash(:info, "Workout ready.")
       |> push_navigate(to: ~p"/session/#{plan.id}")}

    {:error, changeset} ->
      {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_derived()}
  end
end
```

- [ ] **Step 5: Add review template**

Create `lib/burpee_trainer_web/live/plans_live/edit/workout_contract_template.html.heex`:

```heex
<section id="workout-contract-review" class="space-y-5">
  <.qs_surface class="bg-[var(--session-surface)]/60 p-5">
    <div class="space-y-3">
      <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">Generated workout</p>
      <div class="space-y-1">
        <h1 class="text-3xl font-semibold tracking-[-0.055em] text-[var(--session-ink)]">{@contract.title}</h1>
        <p class="text-base font-medium text-[var(--session-ink)]">{@contract.stats}</p>
        <p class="text-sm leading-6 text-[var(--session-muted)]">{@contract.structure}</p>
        <p class="text-sm leading-6 text-[var(--session-muted)]">{@contract.feel}</p>
      </div>

      <div data-structure-map class="flex items-end gap-1.5 pt-3" aria-label="Workout structure preview">
        <%= for mark <- @contract.structure_map do %>
          <span
            title={mark.label}
            class="block w-2 rounded-full bg-[var(--session-ink)]"
            style={"height: #{mark.height}px; opacity: #{mark.shade}; margin-right: #{mark.gap}px"}
          />
        <% end %>
      </div>
    </div>
  </.qs_surface>

  <.qs_surface class="bg-[var(--session-surface)]/50 p-5">
    <p class="text-sm font-semibold text-[var(--session-ink)]">Structure</p>
    <div class="mt-4 space-y-2">
      <div :for={group <- @contract.structure_groups} class="grid grid-cols-[4rem_1fr] gap-3 text-sm tabular-nums">
        <span class="text-[var(--session-muted)]">{group.range}</span>
        <span class="text-[var(--session-ink)]">{group.label}</span>
      </div>
    </div>
  </.qs_surface>

  <form id="start-workout-form" phx-submit="start_workout" class="space-y-3">
    <button id="start-workout" type="submit" class="w-full rounded-xl bg-[var(--session-ink)] px-5 py-4 text-sm font-semibold text-[var(--session-bg)] transition active:translate-y-px phx-submit-loading:opacity-60">
      Start workout
    </button>
    <button id="edit-workout" type="button" phx-click="edit_generated_workout" class="w-full rounded-xl border border-[var(--session-border)] px-5 py-4 text-sm font-semibold text-[var(--session-ink)] transition active:bg-[var(--session-track)]/70">
      Edit workout
    </button>
  </form>
</section>
```

- [ ] **Step 6: Render review from `plan_solution_card_template.html.heex`**

At the top of `plan_solution_card_template.html.heex`, branch review mode before existing content:

```heex
<%= if @creator_phase == :review do %>
  <.workout_contract_template contract={@contract} />
<% else %>
  <%!-- existing editor content remains here until Task 4 replaces it --%>
<% end %>
```

Ensure the existing hidden `#plan-form` is not duplicated inside review. The review uses `#start-workout-form`.

- [ ] **Step 7: Run review tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: PASS. Do not leave an intentionally failing editor-overview test in Task 3; Task 4 adds the editor-overview red test.

- [ ] **Step 8: Commit the generated review**

Run:

```bash
jj describe -m "feat(ui): show generated workout contract review"
jj new
```

---

### Task 4: Readable Editor Overview and Structure Map

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Create: `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`

**Interfaces:**

- Consumes: `@contract`, `Presentation.block_rows/2`, `@plan`, `@live_action`.
- Produces:
  - `#workout-editor-overview`
  - `[data-workout-block-row]`
  - `[data-structure-map]`
  - `#rebalance-unlocked-blocks`
  - `#advanced-constraints-toggle` still available in editor mode.

- [ ] **Step 1: Write failing editor overview tests**

Append under `describe "/workouts/new"`:

```elixir
test "editor overview is readable block cards, not a field table", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view |> element("#generate-workout") |> render_click()
  view |> element("#edit-workout") |> render_click()

  html = render(view)
  assert has_element?(view, "#workout-editor-overview")
  assert html =~ "Edit workout"
  assert html =~ "20 min Six-count"
  assert html =~ "reps ·"
  assert html =~ "blocks"
  assert has_element?(view, "[data-structure-map]")
  assert has_element?(view, "[data-workout-block-row]")
  assert html =~ "Rep every"
  assert html =~ "rest"
  assert html =~ "Rebalance unlocked blocks"

  refute html =~ "Prescription graph"
  refute html =~ "Solver computes"
  refute html =~ ">Pace<"
end
```

Append under `describe "/workouts"` or existing edit-plan tests:

```elixir
test "existing plan edit page opens directly to editor overview", %{conn: conn, user: user} do
  plan = plan_fixture(user, %{"name" => "Readable Edit"})

  {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

  assert has_element?(view, "#workout-editor-overview")
  assert html =~ "Edit workout"
  assert html =~ "Readable Edit"
  assert has_element?(view, "[data-workout-block-row]")
  refute html =~ "Prescription graph"
end
```

- [ ] **Step 2: Run editor overview tests and verify RED**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: FAIL because `#workout-editor-overview` does not exist.

- [ ] **Step 3: Assign locked indexes and selected block state**

In `PlanEditor.State`, add fields:

```elixir
selected_block_index: nil,
locked_block_indexes: MapSet.new(),
creator_phase: :intent
```

Add matching types:

```elixir
selected_block_index: non_neg_integer() | nil,
locked_block_indexes: MapSet.t(non_neg_integer()),
creator_phase: :intent | :review | :editor
```

In `put_editor/2`, mirror:

```elixir
|> assign(:selected_block_index, editor.selected_block_index)
|> assign(:locked_block_indexes, editor.locked_block_indexes)
```

- [ ] **Step 4: Add editor overview template**

Create `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex`:

```heex
<section id="workout-editor-overview" class="space-y-5">
  <.qs_surface class="bg-[var(--session-surface)]/60 p-5">
    <div class="flex items-start justify-between gap-4">
      <div class="min-w-0 space-y-1">
        <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">Edit workout</p>
        <h1 class="text-2xl font-semibold tracking-[-0.045em] text-[var(--session-ink)]">{@contract.title}</h1>
        <p class="text-sm font-medium text-[var(--session-ink)]">{@contract.stats}</p>
      </div>
      <.link :if={@plan} id="editor-start-workout" navigate={~p"/session/#{@plan.id}"} class="rounded-xl bg-[var(--session-ink)] px-4 py-2.5 text-sm font-semibold text-[var(--session-bg)] active:translate-y-px">
        Start
      </.link>
      <button :if={!@plan} id="editor-start-workout" type="submit" form="editor-save-start-form" class="rounded-xl bg-[var(--session-ink)] px-4 py-2.5 text-sm font-semibold text-[var(--session-bg)] active:translate-y-px">
        Start
      </button>
    </div>

    <div data-structure-map class="mt-5 flex items-end gap-1.5" aria-label="Workout structure preview">
      <%= for mark <- @contract.structure_map do %>
        <span title={mark.label} class="block w-2 rounded-full bg-[var(--session-ink)]" style={"height: #{mark.height}px; opacity: #{mark.shade}; margin-right: #{mark.gap}px"} />
      <% end %>
    </div>
  </.qs_surface>

  <.qs_surface class="bg-[var(--session-surface)]/50 p-5">
    <div class="flex items-center justify-between gap-3">
      <p class="text-sm font-semibold text-[var(--session-ink)]">Structure</p>
      <button id="rebalance-unlocked-blocks" type="button" phx-click="rebalance_unlocked_blocks" class="text-sm font-medium text-[var(--session-muted)] active:text-[var(--session-ink)]">
        Rebalance unlocked blocks
      </button>
    </div>

    <div class="mt-4 divide-y divide-[var(--session-border)]">
      <button
        :for={row <- @contract.block_rows}
        type="button"
        phx-click="select_block"
        phx-value-index={row.index}
        data-workout-block-row
        class="w-full py-4 text-left transition active:bg-[var(--session-track)]/50"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="space-y-1">
            <p class="text-sm font-semibold text-[var(--session-ink)]">{row.title}</p>
            <p class="text-sm text-[var(--session-ink)]">{row.headline}</p>
            <p class="text-xs text-[var(--session-muted)]">{row.detail}</p>
            <p :if={row.locked?} class="text-xs font-medium text-[var(--session-muted)]">{row.lock_label}</p>
          </div>
          <span class="text-lg leading-none text-[var(--session-muted)]">…</span>
        </div>
      </button>
    </div>
  </.qs_surface>

  <button id="advanced-constraints-toggle" type="button" phx-click="toggle_advanced_constraints" class="w-full rounded-xl border border-[var(--session-border)] px-5 py-3 text-left text-sm font-medium text-[var(--session-ink)] active:bg-[var(--session-track)]/70">
    Advanced constraints
  </button>

  <div :if={@creator_advanced?} id="advanced-constraints-panel" class="space-y-4">
    <.qs_surface class="bg-[var(--session-surface)]/50 p-5">
      <p class="text-sm font-semibold text-[var(--session-ink)]">Advanced constraints</p>
      <p class="mt-2 text-sm leading-6 text-[var(--session-muted)]">Block pattern, rest placement, and pace overrides are available here. Solver/debug details remain hidden.</p>
      <%!-- Keep existing graph/block pattern controls here only after Task 5 moves them out of default view. --%>
    </.qs_surface>
  </div>

  <form id="editor-save-start-form" phx-submit="start_workout" class="hidden"></form>
</section>
```

- [ ] **Step 5: Render editor overview in `plan_solution_card_template.html.heex`**

Replace the default visible prescription graph with:

```heex
<%= cond do %>
  <% @creator_phase == :review -> %>
    <.workout_contract_template contract={@contract} />
  <% true -> %>
    <.workout_editor_overview_template
      contract={@contract}
      plan={@plan}
      creator_advanced?={@creator_advanced?}
    />
<% end %>
```

Move the existing block-pattern/prescription-graph markup inside the advanced panel in this task. It must not render in default editor overview.

- [ ] **Step 6: Run editor overview tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit the editor overview**

Run:

```bash
jj describe -m "feat(ui): show readable workout editor overview"
jj new
```

---

### Task 5: Focused Block Sheet, Lock Copy, and Rebalance Unlocked Blocks

**Files:**

- Modify: `lib/burpee_trainer/plan_editor/state.ex`
- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Create: `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

**Interfaces:**

- Consumes: selected block index, existing form plan blocks, `PlanEditor.regenerate/1`, `PlanEditor.derived/2`.
- Produces:
  - `PlanEditor.select_block(state, index)`
  - `PlanEditor.close_block(state)`
  - `PlanEditor.lock_block(state, index)`
  - `PlanEditor.unlock_block(state, index)`
  - `PlanEditor.rebalance_unlocked_blocks(state)`
  - LiveView events: `select_block`, `close_block_sheet`, `change_block_sheet`, `toggle_block_lock`, `rebalance_unlocked_blocks`.
  - `#block-edit-sheet` with Reps, Seconds per rep, Rest after, Lock this block, Duplicate, Delete.

- [ ] **Step 1: Write failing PlanEditor lock/rebalance tests**

In `test/burpee_trainer/plan_editor_test.exs`, add:

```elixir
describe "block locks" do
  test "lock_block/2 marks a block index as locked" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})
    {:ok, state} = PlanEditor.regenerate(state)

    {:ok, state} = PlanEditor.lock_block(state, "0")

    assert MapSet.member?(state.locked_block_indexes, 0)
    assert state.manual_edit?
  end

  test "rebalance_unlocked_blocks/1 preserves locked block positions" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})
    {:ok, state} = PlanEditor.regenerate(state)

    locked_block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> hd()
    edited_block = %{locked_block | sets: [%{hd(locked_block.sets) | burpee_count: 17}]}
    form_plan = %{state.form_plan | blocks: [edited_block]}
    state = %{state | form_plan: form_plan, locked_block_indexes: MapSet.new([0]), manual_edit?: true}

    {:ok, rebalanced} = PlanEditor.rebalance_unlocked_blocks(state)
    [first_block | _] = Enum.sort_by(rebalanced.form_plan.blocks, & &1.position)

    assert hd(first_block.sets).burpee_count == 17
    assert MapSet.member?(rebalanced.locked_block_indexes, 0)
  end
end
```

- [ ] **Step 2: Run PlanEditor tests and verify RED**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs
```

Expected: FAIL because lock/rebalance functions and state fields do not exist.

- [ ] **Step 3: Implement PlanEditor lock/rebalance functions**

In `PlanEditor.State`, add `selected_block_index` and `locked_block_indexes` if not already added by Task 4.

In `lib/burpee_trainer/plan_editor.ex`, add:

```elixir
@spec select_block(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
def select_block(%State{} = state, index) do
  case Input.parse_non_negative_index(index) do
    {:ok, index} -> {:ok, %{state | selected_block_index: index}}
    {:error, reason} -> {:error, reason, state}
  end
end

@spec close_block(State.t()) :: {:ok, State.t()}
def close_block(%State{} = state), do: {:ok, %{state | selected_block_index: nil}}

@spec lock_block(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
def lock_block(%State{} = state, index) do
  case Input.parse_non_negative_index(index) do
    {:ok, index} ->
      {:ok,
       %{
         state
         | locked_block_indexes: MapSet.put(state.locked_block_indexes, index),
           manual_edit?: true
       }}

    {:error, reason} ->
      {:error, reason, state}
  end
end

@spec unlock_block(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
def unlock_block(%State{} = state, index) do
  case Input.parse_non_negative_index(index) do
    {:ok, index} -> {:ok, %{state | locked_block_indexes: MapSet.delete(state.locked_block_indexes, index)}}
    {:error, reason} -> {:error, reason, state}
  end
end

@spec rebalance_unlocked_blocks(State.t()) :: {:ok, State.t()}
def rebalance_unlocked_blocks(%State{} = state) do
  locked_blocks = locked_blocks_by_index(state.form_plan, state.locked_block_indexes)

  {:ok, regenerated} = regenerate(state)

  form_plan = restore_locked_blocks(regenerated.form_plan, locked_blocks)

  {:ok,
   %{
     regenerated
     | form_plan: form_plan,
       locked_block_indexes: state.locked_block_indexes,
       manual_edit?: true,
       derived: derived(form_plan, state.input)
   }}
end

defp locked_blocks_by_index(%WorkoutPlan{blocks: blocks}, locked_indexes) when is_list(blocks) do
  blocks
  |> Enum.sort_by(&(&1.position || 0))
  |> Enum.with_index()
  |> Enum.reduce(%{}, fn {block, index}, acc ->
    if MapSet.member?(locked_indexes, index), do: Map.put(acc, index, block), else: acc
  end)
end

defp locked_blocks_by_index(_plan, _locked_indexes), do: %{}

defp restore_locked_blocks(%WorkoutPlan{blocks: blocks} = plan, locked_blocks) when is_list(blocks) do
  blocks =
    blocks
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index()
    |> Enum.map(fn {block, index} -> Map.get(locked_blocks, index, block) end)

  %{plan | blocks: blocks}
end

defp restore_locked_blocks(plan, _locked_blocks), do: plan
```

- [ ] **Step 4: Run PlanEditor tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs
```

Expected: PASS.

- [ ] **Step 5: Write failing LiveView block-sheet test**

Append under `describe "/workouts/new"` in `workouts_live_test.exs`:

```elixir
test "selecting a block opens a focused edit sheet and locking labels the row", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view |> element("#generate-workout") |> render_click()
  view |> element("#edit-workout") |> render_click()
  view |> element("[data-workout-block-row]") |> render_click()

  assert has_element?(view, "#block-edit-sheet")
  html = render(view)
  assert html =~ "Reps"
  assert html =~ "Seconds per rep"
  assert html =~ "Rest after"
  assert html =~ "Lock this block"
  assert html =~ "Duplicate"
  assert html =~ "Delete block"

  view
  |> element("#block-sheet-form")
  |> render_change(%{
    "block" => %{
      "source_block_index" => "0",
      "reps" => "17",
      "sec_per_rep" => "4.2",
      "rest_sec" => "45"
    }
  })

  html = render(view)
  assert html =~ "Locked by you"
  assert html =~ "17 reps"
  assert html =~ "Rep every 4.2s"
  assert html =~ "0:45 rest"
end
```

- [ ] **Step 6: Run block-sheet LiveView test and verify RED**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: FAIL because `#block-edit-sheet` does not exist.

- [ ] **Step 7: Wire block selection/locking LiveView events**

In `edit.ex`, add handlers:

```elixir
def handle_event("select_block", %{"index" => index}, socket) do
  case PlanEditor.select_block(socket.assigns.editor, index) do
    {:ok, editor} -> {:noreply, put_editor(socket, editor)}
    {:error, _reason, _state} -> {:noreply, socket}
  end
end

def handle_event("close_block_sheet", _params, socket) do
  {:ok, editor} = PlanEditor.close_block(socket.assigns.editor)
  {:noreply, put_editor(socket, editor)}
end

def handle_event("toggle_block_lock", %{"index" => index}, socket) do
  locked? = MapSet.member?(socket.assigns.locked_block_indexes, String.to_integer(index))

  result =
    if locked?,
      do: PlanEditor.unlock_block(socket.assigns.editor, index),
      else: PlanEditor.lock_block(socket.assigns.editor, index)

  case result do
    {:ok, editor} -> validate_editor_form(socket, editor)
    {:error, _reason, _state} -> {:noreply, socket}
  end
end

def handle_event("change_block_sheet", %{"block" => block_params}, socket) do
  form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)
  source_block_index = String.to_integer(Map.fetch!(block_params, "source_block_index"))

  set_params = %{
    "burpee_count" => Map.fetch!(block_params, "reps"),
    "sec_per_rep" => Map.fetch!(block_params, "sec_per_rep"),
    "end_of_set_rest" => Map.fetch!(block_params, "rest_sec")
  }

  blocks = update_timeline_set(form_plan.blocks, source_block_index, 0, set_params)
  form_plan = %{form_plan | blocks: blocks}
  editor = %{socket.assigns.editor | form_plan: form_plan, manual_edit?: true}

  case PlanEditor.lock_block(editor, Integer.to_string(source_block_index)) do
    {:ok, editor} -> validate_editor_form(socket, editor)
    {:error, _reason, _state} -> {:noreply, socket}
  end
end

def handle_event("rebalance_unlocked_blocks", _params, socket) do
  {:ok, editor} = PlanEditor.rebalance_unlocked_blocks(socket.assigns.editor)
  validate_editor_form(socket, editor)
end
```

- [ ] **Step 8: Add block sheet template**

Create `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex`:

```heex
<div :if={is_integer(@selected_block_index)} id="block-edit-sheet" class="fixed inset-x-0 bottom-0 z-40 rounded-t-3xl border border-[var(--session-border)] bg-[var(--session-surface)] p-5 shadow-2xl sm:relative sm:rounded-2xl sm:shadow-none">
  <% row = Enum.at(@contract.block_rows, @selected_block_index) %>
  <div class="flex items-start justify-between gap-4">
    <div class="space-y-1">
      <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">Edit block</p>
      <h2 class="text-xl font-semibold tracking-[-0.035em] text-[var(--session-ink)]">{row.title}</h2>
      <p class="text-sm text-[var(--session-muted)]">{row.headline}</p>
    </div>
    <button type="button" phx-click="close_block_sheet" class="rounded-lg px-2 py-1 text-sm text-[var(--session-muted)] active:bg-[var(--session-track)]/70">Close</button>
  </div>

  <form id="block-sheet-form" phx-change="change_block_sheet" class="mt-5 grid grid-cols-3 gap-3">
    <input type="hidden" name="block[source_block_index]" value={row.source_block_index} />
    <label class="space-y-2">
      <span class="text-xs font-medium text-[var(--session-muted)]">Reps</span>
      <input type="number" name="block[reps]" value={row.reps} min="1" class="w-full rounded-lg border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-3 text-center text-sm tabular-nums text-[var(--session-ink)]" />
    </label>
    <label class="space-y-2">
      <span class="text-xs font-medium text-[var(--session-muted)]">Seconds per rep</span>
      <input type="number" name="block[sec_per_rep]" value={row.sec_per_rep} min="0.1" step="0.1" class="w-full rounded-lg border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-3 text-center text-sm tabular-nums text-[var(--session-ink)]" />
    </label>
    <label class="space-y-2">
      <span class="text-xs font-medium text-[var(--session-muted)]">Rest after</span>
      <input type="number" name="block[rest_sec]" value={row.rest_sec} min="0" class="w-full rounded-lg border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-3 text-center text-sm tabular-nums text-[var(--session-ink)]" />
    </label>
  </form>

  <div class="mt-5 flex flex-wrap items-center gap-2">
    <button id="block-lock-toggle" type="button" phx-click="toggle_block_lock" phx-value-index={@selected_block_index} class="rounded-lg border border-[var(--session-border)] px-3 py-2 text-sm font-medium text-[var(--session-ink)] active:bg-[var(--session-track)]/70">
      {if row.locked?, do: "Unlock block", else: "Lock this block"}
    </button>
    <button type="button" phx-click="copy_block" phx-value-index={row.source_block_index} class="rounded-lg border border-[var(--session-border)] px-3 py-2 text-sm font-medium text-[var(--session-muted)] active:bg-[var(--session-track)]/70">Duplicate</button>
    <button type="button" class="rounded-lg px-3 py-2 text-sm font-medium text-error/80 active:bg-[var(--session-track)]/70">Delete block</button>
  </div>
</div>
```

This sheet displays real values and wires Reps, Seconds per rep, and Rest after through `change_block_sheet`. The change handler marks the source block as locked so the row immediately shows `Locked by you`.

- [ ] **Step 9: Render block sheet below editor overview**

In `workout_editor_overview_template.html.heex`, after the structure list, render:

```heex
<.block_sheet_template
  contract={@contract}
  selected_block_index={@selected_block_index}
/>
```

Pass `selected_block_index` from `plan_solution_card_template.html.heex`:

```heex
<.workout_editor_overview_template
  contract={@contract}
  plan={@plan}
  creator_advanced?={@creator_advanced?}
  selected_block_index={@selected_block_index}
/>
```

- [ ] **Step 10: Run block-sheet tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: PASS.

- [ ] **Step 11: Commit block sheet and locking**

Run:

```bash
jj describe -m "feat(ui): add focused block sheet with locks"
jj new
```

---

### Task 6: Product Conflict and Infeasible States

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`

**Interfaces:**

- Consumes: existing `plan_feedback/3`, `feedback_from_message/1`, `@derived`, `@solver_error`, `@timeline_error`.
- Produces: product copy and actions for manual conflict/infeasible states:
  - `Workout no longer fits 20:00`
  - `You are 0:42 over.`
  - `This cannot fit in 20:00`
  - `The locked blocks and rests exceed the duration.`
  - Actions: `Rebalance unlocked blocks`, `Keep 20:42`, `Undo change`, `Show locked blocks`, `Unlock all`, `Allow longer workout`, `Undo`.

- [ ] **Step 1: Write failing product-state tests**

Replace or update impossible prescription tests in `workouts_live_test.exs` with product copy assertions:

```elixir
test "impossible prescription uses product conflict copy and actions", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view
  |> element("#creator-duration-form")
  |> render_change(%{"target_duration_min" => "1"})

  view |> element("#generate-workout") |> render_click()

  html = render(view)
  assert has_element?(view, "#plan-solver-impossible")
  assert html =~ "This cannot fit in 1:00"
  assert html =~ "The locked blocks and rests exceed the duration."
  assert html =~ "Show locked blocks"
  assert html =~ "Unlock all"
  assert html =~ "Allow longer workout"
  assert html =~ "Undo"
  refute html =~ "No runnable prescription yet"
  refute html =~ "No workable prescription"
end
```

Add a manual conflict test if Task 5 exposes a way to create a duration mismatch. If not, add a unit test against `plan_feedback/3` by extracting it to a testable helper in `Presentation` or keeping the LiveView test for infeasible only.

- [ ] **Step 2: Run product-state tests and verify RED**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: FAIL because current copy says `No workable prescription` or similar.

- [ ] **Step 3: Update feedback copy**

In `edit.ex`, change `plan_feedback/3` for binary solver errors to return product copy:

```elixir
defp plan_feedback(solver_error, _derived, plan_input) when is_binary(solver_error) do
  %{
    title: "This cannot fit in #{Fmt.duration_sec(plan_input.target_duration_min * 60)}",
    message: "The locked blocks and rests exceed the duration.",
    actions: ["Show locked blocks", "Unlock all", "Allow longer workout", "Undo"]
  }
end
```

Change the derived mismatch branch:

```elixir
defp plan_feedback(nil, %{both_ok: false} = derived, plan_input) do
  over_by = max(0, round(derived.duration_sec - plan_input.target_duration_min * 60))

  %{
    title: "Workout no longer fits #{Fmt.duration_sec(plan_input.target_duration_min * 60)}",
    message: "You are #{Fmt.duration_sec(over_by)} over.",
    actions: ["Rebalance unlocked blocks", "Keep #{Fmt.duration_sec(round(derived.duration_sec))}", "Undo change"]
  }
end
```

If this creates awkward copy when reps mismatch but duration does not exceed, use:

```elixir
over_by = max(0, round(derived.duration_sec - plan_input.target_duration_min * 60))
message = if over_by > 0, do: "You are #{Fmt.duration_sec(over_by)} over.", else: "Reps are #{derived.burpee_count}, target is #{plan_input.burpee_count_target}."
```

- [ ] **Step 4: Render feedback actions as buttons where actionable**

In `plan_solution_card_template.html.heex`, convert action tags to buttons for known actions:

```heex
<button :for={action <- @plan_feedback.actions} type="button" class="rounded-lg border border-[var(--session-border)] px-3 py-2 text-xs font-medium text-[var(--session-muted)] active:bg-[var(--session-track)]/70">
  {action}
</button>
```

Only wire events for actions that already exist (`Rebalance unlocked blocks`). Leave non-wired actions visually secondary and non-primary until their behavior is implemented.

- [ ] **Step 5: Run product-state tests and verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit product states**

Run:

```bash
jj describe -m "feat(ui): add product conflict copy for workout editor"
jj new
```

---

### Task 7: Regression Sweep, Formatting, and Precommit

**Files:**

- Modify tests as needed only to align with intentional creator/editor copy changes.
- Do not change production code unless verification finds a real regression.

**Interfaces:**

- Consumes: all previous tasks.
- Produces: verified creator/editor refactor with green focused tests and project precommit.

- [ ] **Step 1: Run focused LiveView and presentation tests**

Run:

```bash
mix test \
  test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs \
  test/burpee_trainer_web/live/workouts_live_test.exs \
  test/burpee_trainer/plan_editor_test.exs
```

Expected: PASS. If failures are from outdated assertions that intentionally referenced `Block pattern`, `Prescription graph`, or `Pace` in default UI, update the tests to the new contract copy. If failures reveal behavior regressions, fix the production code and rerun.

- [ ] **Step 2: Run LSP diagnostics on touched Elixir files**

Run via Pi LSP diagnostics or command-equivalent diagnostics on these files:

```text
lib/burpee_trainer_web/live/plans_live/edit.ex
lib/burpee_trainer_web/live/plans_live/edit/presentation.ex
lib/burpee_trainer/plan_editor.ex
lib/burpee_trainer/plan_editor/state.ex
test/burpee_trainer_web/live/workouts_live_test.exs
test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs
test/burpee_trainer/plan_editor_test.exs
```

Expected: no blocking diagnostics.

- [ ] **Step 3: Format**

Run:

```bash
mix format
```

Expected: exit 0.

- [ ] **Step 4: Run project precommit**

Run:

```bash
mix precommit
```

Expected: exit 0. If it fails, fix the reported issues and rerun `mix precommit` until it exits 0.

- [ ] **Step 5: Inspect final diff**

Run:

```bash
jj diff --stat
jj diff --git
```

Expected: diff only touches creator/editor UI, presentation helper/tests, and any minimal style utilities; no Home/overview palette rewrite.

- [ ] **Step 6: Final commit description**

Run:

```bash
jj describe -m "feat(ui): refactor workout creator editor contract"
```

Do not run `jj new` after the final task unless the user asks for a fresh empty change.

---

## Self-Review Against Spec

- **Creator/editor first:** Covered by Tasks 2–6. Home/overview is deferred.
- **Keep current colors:** Global constraint and Task 7 diff check explicitly prevent palette changes.
- **Readable contract before editing:** Tasks 1, 3, and 4 implement contract, structure map, grouped preview, and readable rows.
- **Intent-first creator:** Task 2 implements burpee type, duration, intent, difficulty, Generate workout, and collapsed Advanced constraints.
- **Generated review:** Task 3 implements review contract, structure map, Start workout, and Edit workout.
- **Editor overview:** Task 4 implements readable block rows and Rebalance unlocked blocks.
- **Block sheet:** Task 5 implements selected block sheet with Reps, Seconds per rep, Rest after, Lock, Duplicate, Delete surface.
- **Manual edits/locking:** Task 5 adds lock state and preserves locked blocks during rebalance.
- **Conflict/infeasible states:** Task 6 updates copy/actions.
- **No solver/debug leakage:** Tasks 2–4 move block pattern/prescription graph out of default UI; Task 7 verifies default assertions.
- **Testing:** Each task starts with failing tests and verifies green before commit.

No placeholders remain in this plan. Any implementation worker should preserve TDD order and stop for review after each task.
