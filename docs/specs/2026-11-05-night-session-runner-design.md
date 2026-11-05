# Night Session Runner Design

**Date:** 2026-11-05
**Status:** Approved
**Scope:** The plan session runner, from camera setup to the last rep: a night palette, one
number readable from 1.5 m, pace shown by the fill's colour and the beep's pitch, a breathing
sink in rest, and sets that follow the camera when it is counting.
**Mockup:** <https://claude.ai/artifact/Tqxyma8utx6XVWPc6WEhmD> (v20)

## Context

The athlete is 1–1.5 m from the phone for a HIIT session. The runner today is a light
surface with an orange per-rep fill, a slate rest that breathes on an 8.4 s cycle (from a
Headspace reference), small set and rep readouts at the top, and a pause screen whose actions
are hard to see.

With the camera counting, the number counts the camera's reps but the fill follows the
clock. A fast athlete sees the fill on rep 5 while the number says 3 left. Being ahead buys
nothing visible, so a breather inside an unbroken set looks like falling behind. Being
behind when the set's time ends starts the rest anyway: reps after its first two seconds
(`LATE_REP_GRACE_MS`) are not counted, and the set's missing reps disappear without a sign.

## Goals

1. One number and one shape per screen, big enough to read from 1.5 m.
2. While the camera counts, the number and the fill describe the same rep.
3. Ahead, steady and behind are visible from across the room, without words, and audible
   without looking.
4. A breather earned by being ahead costs nothing; a slow set may run into its rest.
5. Rest guides fast deep breathing: in through the nose, out through the mouth.
6. Camera setup, the runner and pause share one night ground, so starting a workout never
   flashes from light to dark.

## Non-goals

- Voice cues or pace words. Sounds are beeps only.
- Recovering camera trust after it is lost (degradation stays sticky).
- The video runner (`VideoLive.Show`), completion review and Save, which keep the app's
  light system.
- Changing workout timelines, the rest fitter or how sessions are saved.

## Palette

The runner is the app turned inside out: the app's ink (`--ink`) is the ground and its paper
(`--color-base-100`) the numbers, so the session is the same family as Home, only at night.
Pace and breath take colours from the owner's no-clown-fiesta theme; like the app's other
colour, they are data. These replace the session's phase colours in `docs/ui.md` and apply
only inside the session surface.

| Token | Value | Meaning |
|---|---|---|
| `--session-ground` | `#262722` (`--ink`) | the ground of every runner screen |
| `--session-ink` | `#F4F2EE` (`--color-base-100`) | the number, icons, the workout line's elapsed part, filled pills |
| `--session-muted` | `#A9A79F` | secondary text (rest's sets done, pause, camera setup) |
| `--session-track` | `#3A3B35` | the workout line's track; quiet pills and round buttons |
| `--session-on-fill` | `#262722` | the number where a fill or the sink's disc covers it |
| `--pace-steady` | `#FFA557` | the rep fill, on the beat; the final-three pulse |
| `--pace-ahead` | `#90A959` | the rep fill, ahead; the camera has you (setup) |
| `--pace-behind` | `#B46958` | the rep fill, behind |
| `--session-breath` | `#BAD7FF` | the sink's disc and its air |
| `--session-last` | `#F4BF75` | the number on the set's last rep |

## Into and out of the runner

The Play pill on Home is ink, the runner's ground. Tapping it grows an ink curtain from the
pill's box to the screen (`--motion-settle`, `--ease-out`), and the camera setup or count-in
appears on it. Play is a live navigation to another LiveView, which the page-patch view
transitions cannot capture, so the curtain is a fixed layer on `<body>`
(`assets/js/session_curtain.mjs`). Leaving a night screen by live navigation (Back from camera
setup) covers the screen in ink and shrinks it into Home's Play pill. Abort reloads the page
and completion review is light, so neither runs it. With reduced motion the page simply
changes.

## The workout line

One bar for the whole workout, showing time elapsed. It is 10 pt tall with round ends,
inset 16 pt from the sides and placed below the top safe area, so the Dynamic Island never
covers it. Track `--session-track`, elapsed part `--session-ink`. It replaces the
set and rep readouts at the top of the runner.

## Screens

Every screen is built from four parts, the ones that make pause read like Home:

- **The workout line** at the top (not on camera setup).
- **The title block:** a title (`--text-title`, 600, `--session-ink`) and one muted line under it
  (`--text-body`, `--session-muted`), centred, 150 pt from the top. Camera setup, count-in and
  pause have one; sets and rest do not.
- **The hero**, centred on the screen's middle: the number, the sink's disc, the pause mark.
- **The foot slot**, 120 pt above the bottom: the screen's one secondary thing (rest's `7/20`,
  the camera chip). Every icon in the runner is the same **chip**: a 48 pt (`--pill-h`) quiet
  round button in `--session-track` with a 24 pt heroicon in `--session-ink`.

The number is Geist 700 with tight tracking and tabular figures, fitted to about half the
screen's width for one or two digits. Where a fill or the disc passes over it, the part
that is covered draws in `--session-on-fill`, so it stays sharp at any fill level.

### Camera setup

The camera feed fills the screen (mirrored, cover) under a soft vignette, with the pose
skeleton as a thin (3 pt) `--session-ink` line at 80%, turning `--pace-ahead` once readiness
is met. The title block carries the status and the workout's name under it ("Step into frame"
/ the workout; "Hand up" / "or hold still"; "Got you" / the workout; "Starting camera";
"Camera unavailable" / its reason), over a gradient that keeps it legible; the back arrow sits
above it at the top left. Opting out is the camera-slash chip in the foot slot, labelled
"Continue without camera" for screen readers and as its title; no visible text. Retry is the
arrow-path chip in the same slot when the camera fails. The screen's flow and readiness rules
are unchanged.

### Count-in

The title block stays where camera setup had it: the workout's name, and "20 sets · 160 reps"
under it. The hero is the numeral 3, 2, 1 in `--session-ink`, each with the lead beep and an
orange (`--pace-steady`) ring pulsing out; then the first rep beep and the set.

### A set

One screen for every set, unbroken or even-paced, with or without the camera: the reps left,
centred, and a fill that rises over each rep and drains through the gap after it (see
Beats). The fill moves smoothly, easing about 50 ms behind its target, never jumping. When the
camera counts a rep, a thin ring pulses from the number and the counted click plays. The last
rep's number is `--session-last` where the fill does not cover it.

The number never turns into a clock or count-in numerals inside a set: the draining fill is
the countdown to the next rep, and a gap over three seconds gets the lead beep on each of its
last three seconds. This replaces the blue `work_recovery` screen and the 3, 2, 1 numerals
before each rep of an even-paced set.

### Rest

The time left as `0:00` (`m:ss`; ten minutes and more at a smaller size), centred inside the
sink's disc. Below it, sets done over sets in the workout (`7/20`) in
`--session-muted`, 44 pt 600: secondary to the time, still readable at 1.5 m. It is the
only other thing on screen besides the workout line.

**The sink.** A solid disc of `--session-breath` (a soft radial gradient from `#D3E6FF` to
`#A9C9F3`) holds the time; its radius moves between 23% and 32% of the screen's width. Around
it, air whirls into and out of it like water in a sink. The air is about 170 specks in
`--session-breath` that persist through the rest and are moved by the breath:

- **Speed follows the breath.** A speck's inward (or outward) speed is the disc's rate of
  change, times a reach of about 0.8 of `r_max` (half the screen's diagonal), easing off with
  distance (`(R/r)^0.35`). So the air rushes in at the start of the nose breath (the sniff),
  coasts, stops at the turn, and is pushed out fastest in the middle of the mouth breath.
- **It swirls.** Each speck turns around the disc faster the closer it is (`∝ (R/r)^0.8`),
  more when the breath moves faster, and never quite stops, so the paths curve like a
  whirlpool.
- **The same air goes in and out.** A speck that reaches the disc on the in-breath waits
  inside it, and the out-breath releases waiting specks from the disc's edge at random angles.
  Specks pushed past `r_max` wait outside, and the next in-breath brings them back in from
  the outer ring. Nothing appears or vanishes on a timer.
- **Trails are real motion:** each speck draws the path it took over its last 15 frames,
  tapering, so trails are long when the air rushes and dots when it pauses.
- **Each speck is a little different:** speed (±30%), size and brightness. Each path also
  wobbles slightly (a slow sine on radius and angle, per speck).
- A glow around the disc brightens on the in-breath.

The breath starts with the rest. 2 s in and 3 s out is 12 breaths a minute, deep, with the
longer out-breath. It is faster than calm slow breathing (about 6 a minute), which is too
slow right after a hard set, and longer on the way out, which brings the heart rate down.

**The last three seconds.** The air stops entering and leaving the disc, and the disc shrinks to nothing, eased, over
the last three seconds. On each of 0:03, 0:02 and 0:01 an orange ring pulses and the lead
beep plays. The number turns `--session-ink` as the disc leaves it. Then the rep beep and
the set begins.

### Camera lost

When the camera is lost, one low buzz plays and the camera-slash chip shows in the foot slot
for the rest of the workout.
The fill returns to the clock and `--pace-steady`; pace colours and pitches stop. Camera
trust is never restored within the workout.

### Pause

Laid out like Home, at Home's sizes, since the athlete walks up for this: the workout's name
as the title (`--text-title`), "Set 7 of 20 · 12:40 left" in `--session-muted`
(`--text-body`), then the pause mark (two `--session-ink` bars, about 100 pt tall). A tap
anywhere outside the icons resumes, as a tap pauses today. Below the mark, two quiet round
icon buttons (`--pill-h`, `--session-track`), each with an `aria-label` and `title`:

- **Finish early:** `hero-flag`.
- **Abort:** `hero-x-mark`. The first tap arms it: over `--motion-settle` the title block and
  the pause mark fade up and away while "Abort workout?" and "It won't be saved." fade in
  where the pause mark was, Finish early shrinks out, and the abort slides to the centre,
  a little larger, in `--pace-behind`. The second tap aborts and deletes the started session.
  Tapping elsewhere or Escape runs it back and stays paused (a tap on the screen does not
  resume while armed). This replaces the Keep and Abort pills: one button answers.
- **Finish early** asks the same way: "Finish early?" and "What you've done is kept.", Abort
  steps aside and the flag slides to the centre filled in `--session-ink`; the second tap
  opens the finish screen.

No words on the actions, per `docs/ui.md` 4a2. The workout line stays at the top.

## Beats

A set is a run of beats. No schema or compiler change: a work event already carries `reps`,
`sec_per_rep` (`c`) and `sec_per_burpee` (`a`, or `c` when unset). From the set's start, rep
*k* (from 1) has its **beat** at `(k−1)·c` and is **due** at `(k−1)·c + a`. Unbroken sets have
`a = c`; even-paced sets have a gap of `c − a` after each rep. With *n* reps counted, the rep
you are on is *n + 1*. Beats never move; the rep beep sounds on each.

**The fill.**

- **From the beat to the due time** it rises from empty to full.
- **Past the due time** it holds full until the rep is done.
- **When the rep is done** it drains from where it stands to empty at the next beat. That is
  the gap: planned in an even-paced set, earned by finishing early, or zero for an unbroken rep
  done on time. As it starts to drain, the block fades away (`--motion-quick`) and only its
  top edge stays: a bar 4.5% of the screen's width tall in the full pace colour, sinking to the
  bottom by the next beat, with the number in `--session-ink`. From across the room a rising
  block means go and a sinking line means wait, with no dimmed, muddy colour.
- **The set's last rep** has no gap; the rest follows (see Sets that follow the camera).

A rep is done when the camera counts it; without the camera, or after it is lost, at its due
time.

**Pace** (camera trusted, workout segment only) colours the fill and pitches the rep beep:

- **Behind:** now is past the due time of the rep you are on. Stays until the camera counts
  it.
- **Ahead:** not behind, and your last counted rep came at least a fifth of its rep time
  (`0.2·a`) before its due time; the drain that follows is the time you earned. Shorter
  margins read as steady, so the colour never flickers for a rep that only just beat its time.
- **Steady:** otherwise, before the first rep is counted, and always without the camera.

The colour changes over about 0.2 s.

## Sets that follow the camera

While the camera is trusted, a gap or a rest starts when the camera counts the rep before it,
early or late. The next rep or set always keeps its beat.

1. **Early.** As now: the set ends when its last rep is counted, and the rest gains the time.
   Inside a set, an early rep drains longer and green to the next beat.
2. **Late.** When a set's time ends short of its reps, the set runs on into the rest: the
   set screen stays, behind and red, and reps keep counting for that set. When the last one
   is counted the rest screen shows the time left, shortened by the overrun.
   Inside a set nothing is cut short: a late rep holds the fill full and red through the next
   beat (whose beep is the behind pitch) until it is counted.
3. **Still short at 0:03.** The count-in takes over three seconds before the next set with its
   lead beeps; the missing reps stay missing, and the next set starts with its own count.
4. **The last set** runs on until the camera counts its last rep or the athlete finishes
   early from pause. The two-second wait for a last rep after the workout's time
   (`LATE_REP_GRACE_MS`) becomes this open wait while the set is short. A complete last set
   finishes as now.

Which reps count changes accordingly: a rep landing in a rest counts for the set before it
while that set is short of its reps and the count-in has not started. Otherwise the existing
two-second grace applies.

## Sounds

Built as `SessionAudio` builds them today. No new sounds without a meaning.

| Sound | When | Build |
|---|---|---|
| Rep, steady | each beat, steady | today's rep beep |
| Rep, ahead | the same, ahead | today's rep beep × 1.26 (a third higher) |
| Rep, behind | the same, behind | today's rep beep × 0.75 (a fourth lower) |
| Last rep | the last rep's window starts | rep beep, then a 987.77 Hz chime 0.16 s later |
| Counted | the camera counts a rep | 1568 Hz sine, 35 ms, quiet |
| Rest | the rest screen shows | chimes 783.99 Hz then 523.25 Hz, 0.22 s apart |
| Count-in | 0:03, 0:02, 0:01 before a set; the last three seconds of a gap over 3 s inside a set | today's lead beep |
| Camera lost | the camera is lost | 146.83 Hz square, 0.32 s |

Without the camera, every rep beep is the steady one and the counted click never plays.

## Motion and accessibility

- `prefers-reduced-motion`: the disc stays at its middle size with no flow; fills step
  instead of easing; no ring pulses; the Play-pill transition cross-fades. Colours, numbers
  and sounds are unchanged.
- Pace is never colour alone: the fill's shape (a rising block, a sinking line, a block held
  full) and the beep's pitch carry it too.
- Colour changes use the app's `--motion-quick` and `--ease-out`.
- The runner keeps its screen-reader heading and its polite live region for the reps left
  and the rest's time; decorative layers stay `aria-hidden`.
- Resume (the whole screen), Finish early and Abort keep 44 pt targets or larger; the icon
  buttons carry `aria-label`s, and the armed Abort announces itself ("Abort workout? It won't be saved. Tap again to abort.").

## Supersedes

- `2026-07-13-workout-session-redesign-design.md`: the visual language, active work state
  and rest sections; the 8.4 s breathing cycle.
- `2026-07-13-rest-animation-refinement-design.md`: the rest surface and its final-five
  transition.
- `2026-07-28-client-authoritative-workout-session-design.md`: "Which camera reps count"
  (rests and the last set, above) and "Intra-rep recovery and rest": recovery inside a set is
  the fill's drain, not a blue screen with a clock and 3, 2, 1 numerals. "Camera tracking never controls the workout clock" was
  already relaxed by camera-paced sets; this extends it to late sets, still never moving a
  set's start.

## Implementation surface

- `assets/js/hooks/session_display_model.mjs`: beats, the fill level and pace from the
  counted reps and their times (replacing `workVisualState`'s `work_recovery` and in-set
  `rest_count_in`); the overrun and count-in takeover; the elapsed-time workout line only.
- `assets/js/hooks/session_segment_fsm.mjs`: a late set extends into its rest
  (the counterpart of `endSetEarly`), the count-in cut-off, the last set's open wait.
- `assets/js/hooks/session_hook.js`: rep eligibility in a rest while the set is short;
  pace-pitched rep cues; the counted cue.
- `assets/js/hooks/session_audio.mjs`: ahead and behind pitches, counted, rest, lost.
- `assets/js/hooks/session_renderer.mjs` and a canvas layer for the sink (its streaks
  are too many for DOM nodes); CSS for the night tokens, camera setup and pause.
- `lib/burpee_trainer_web/components/session_components.ex`: camera setup full-bleed,
  the top readouts replaced by the workout line, pause layout.
- `docs/ui.md`: the session palette replaces Phase colours.

## Testing

- Pure display-model tests over beats, for an unbroken and an even-paced set: the fill rises
  from beat to due, holds full past due, drains from where it stands to empty at the next
  beat once the rep is done; the ahead threshold; steady before the first count; reps done at
  their due time without the camera and after loss; lead beeps only for gaps over 3 s.
- Segment tests: an early set ends and its rest grows (existing); a late set runs into its
  rest and the rest shrinks; the count-in at 0:03 cuts a short set off and the next set
  starts on time with its own count; the last set waits for its last rep or Finish early.
- Rep eligibility: a rep in a rest counts for a short set before the count-in and not after;
  the two-second grace still applies to a complete set.
- Flow test: a camera session that is ahead, steady, behind and runs into a rest keeps the
  number and the fill on the same rep throughout.
- Accessibility: reduced motion stops the sink's motion; pause controls keep 44 pt targets.
- Manual (iPhone, after deploy): readable at 1.5 m; the workout line clear of the Dynamic
  Island; the sink smooth at 60 fps without heating the phone over a 30-minute workout.
