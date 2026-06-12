# Quiet Stone UI Refactor Design

## Context

The app should shift from a dark, electric-blue fitness dashboard toward a light, warm, minimal product interface. The desired references are Notion's restraint and Anthropic's warm neutral palette: polished, tasteful, and free of visual bloat.

This design applies across the whole authenticated app: Home, Workouts, Stats, the plan editor, and the session runner. The first implementation pass should establish the shared visual system before deeper screen-specific restructuring.

## Design goals

1. Make the default app experience light, warm, and calm.
2. Preserve an optional dark mode as a warm-charcoal companion, not the primary identity.
3. Reduce visual bloat by replacing excessive cards and saturated accents with whitespace, typography, and thin rules.
4. Keep training action-first: the interface should make starting a workout feel obvious and immediate.
5. Keep the app polished and durable by centralizing palette and typography decisions in shared tokens.

## Visual direction: Quiet stone

Quiet stone is a warm minimal style:

- Warm stone/off-white background, never pure white.
- Mostly transparent sections instead of heavy filled cards.
- Filled surfaces only when they create useful emphasis: primary actions, modals, focused panels, or selected states.
- Thin warm-gray rules for separation.
- Muted clay/terracotta accents used sparingly.
- Ink-like near-black text on light backgrounds.
- Warm charcoal dark mode, avoiding blue-black or neon accents.

The interface should feel quiet and intentional. It should not feel like a SaaS dashboard, a CRUD admin panel, or a high-contrast fitness gamification app.

## Color system

### Light default

Use these as the semantic target palette. Exact values may be tuned during implementation for contrast.

| Token | Purpose | Target |
| --- | --- | --- |
| `--session-bg` | App background | `#F4F2EE` warm stone |
| `--session-surface` | Filled panel surface | `#FAF8F3` soft paper |
| `--session-surface-alt` | Subtle alternate surface | `#EFECE4` |
| `--session-ink` | Primary text | `#20201D` charcoal ink |
| `--session-muted` | Secondary text | `#74716A` stone gray |
| `--session-soft-muted` | Tertiary text | `#9A9489` |
| `--session-border` | Rules and seams | `#DAD6CE` |
| `--session-accent` | Rare accent | `#A77B5D` muted clay |
| `--session-accent-strong` | Strong accent, rare | `#8F5F46` |

### Dark optional

Dark mode should mirror the warm tone instead of returning to the old blue-gray/electric-blue identity.

| Token | Purpose | Target |
| --- | --- | --- |
| `--session-bg` | App background | `#181614` warm charcoal |
| `--session-surface` | Filled panel surface | `#211F1B` |
| `--session-surface-alt` | Subtle alternate surface | `#2A2722` |
| `--session-ink` | Primary text | `#F3EEE6` |
| `--session-muted` | Secondary text | `#B8AEA1` |
| `--session-soft-muted` | Tertiary text | `#8F867A` |
| `--session-border` | Rules and seams | `#39342D` |
| `--session-accent` | Rare accent | `#C08A68` |
| `--session-accent-strong` | Strong accent, rare | `#D09A78` |

### Accent rules

- Do not use saturated blue as primary UI chrome.
- Clay/terracotta should not flood the interface. It is for small emphasis, selected state, or a single strong callout.
- Primary action buttons may use ink fill with light text. Clay is secondary brand warmth, not necessarily the primary button color.
- Status colors should be quieter than before and should not dominate healthy/default states.

## Typography system

Use **Geist refined**.

- Keep Geist as the only app font family.
- Use a small set of weights: 400, 500, 600. Avoid 700/900 except where already required and justified.
- Let hierarchy come from type size, tracking, and whitespace.
- Use negative tracking on large headings.
- Use tabular numerals for timers, counts, and stats.
- Keep labels at 12-13px, muted, and quiet.
- Avoid all-caps except for tiny metadata labels with generous letter spacing.

Suggested scale:

| Role | Size | Weight | Tracking |
| --- | ---: | ---: | ---: |
| Hero/page heading | 36-42px | 600 | `-0.045em` |
| Section heading | 18-24px | 500-600 | `-0.025em` |
| Primary metric | 24-32px | 600 | `-0.025em` |
| Body | 14-16px | 400 | normal |
| Label/meta | 12-13px | 400-500 | optional `0.06em` only when uppercase |
| Timer | context-specific | 500-600 | tabular numerals |

## Layout and surface rules

1. Prefer page-level whitespace over nested cards.
2. Use thin rules and section spacing before using filled boxes.
3. A card represents a discrete concept with meaningful internal structure. Do not wrap single labels or isolated numbers in cards.
4. The primary action surface may use a filled panel so it owns visual priority.
5. Secondary content should be flatter: transparent sections, subtle dividers, low-contrast labels.
6. Avoid competing CTAs. Each screen gets one dominant action.
7. Destructive or uncommon actions should be visually demoted.

## Screen-level direction

### App shell

- Keep navigation simple and legible.
- Navigation should feel like part of the page, not a heavy app chrome layer.
- Mobile bottom nav should remain reachable but visually quieter.
- Desktop top nav may use text labels or clear icon+label treatment if it improves clarity.
- Theme toggle should be subtle and not compete with training actions.

### Home

Home is an action surface. Its job is to help the user start training fast.

- Lead with one workout-starting action.
- Show only enough weekly/streak context to orient the user.
- Avoid historical dashboard content on Home.
- Use the strongest visual weight for the suggested/default workout and its Start action.
- Keep log-past-session as a secondary affordance.

### Workouts

Workouts is a browsing and management surface.

- Use a quiet list or restrained cards with consistent item structure.
- Make starting a workout easy from each item.
- Keep editing/management actions secondary.
- Avoid making every workout card equally loud.

### Stats

Stats is a reading surface.

- It can be denser than Home, but should still follow the Quiet stone palette.
- Lead with the most important progress/status signal.
- Charts should use warm neutrals and muted data colors.
- Historical lists should prioritize scanability over decorative cards.

### Plan editor

The plan editor is an input/output surface.

- Separate user intent, constraints, and generated output.
- Keep solver or validation details visually secondary unless they block progress.
- Use warm rules and restrained panels rather than bright validation borders.

### Session runner

The session runner is an active physical-use surface.

- Maintain strong legibility and room-test readability.
- Timer/current phase may use larger type than the rest of the app.
- Controls must remain obvious and tappable.
- Align colors with Quiet stone but do not sacrifice contrast during active workouts.

## Implementation strategy

1. Update shared theme tokens in `assets/css/app.css`.
2. Refine shared app shell components in `lib/burpee_trainer_web/components/layouts.ex`.
3. Apply the visual system to Home first.
4. Apply the same system to Workouts and Stats.
5. Polish the session runner last, preserving legibility and interaction safety.

## Non-goals

- Do not introduce a new component library.
- Do not add a new font family for this pass.
- Do not redesign data models or workout logic.
- Do not add animation-heavy interactions.
- Do not copy Anthropic's brand directly; use it as tonal inspiration only.

## Success criteria

- The default authenticated app loads in a light warm theme.
- Dark mode remains available and uses warm charcoal tokens.
- Blue is no longer the primary app accent.
- Major app surfaces share the same palette, typography discipline, and surface rules.
- Home reads as an action-first training launcher, not a dashboard.
- Visual clutter is reduced: fewer heavy panels, fewer loud accents, fewer competing CTAs.
- Existing LiveView behavior and tests continue to pass.
