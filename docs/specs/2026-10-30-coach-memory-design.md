# The coach's memory, kept the way the Hermes agent keeps it

The coach remembers the athlete the way the Hermes agent (Nous Research) remembers its user:
a small, bounded memory that the coach curates itself with one tool, read back into every
turn as a frozen snapshot. It replaces the 20 one-line notes guarded by `Memory.Ops` and
rewritten only after events (`2026-10-14-coach-card-design.md`, "The coach's memory").

## Two parts, each bounded

| Part | Holds | Limit |
|---|---|---|
| `user`: USER PROFILE | who the athlete is: when and where they train, their body, likes and dislikes, what they train for, how they want to be coached | 1,375 chars |
| `memory`: MEMORY | the coach's notes on coaching them: what has worked, agreements made, how they take a hard week | 2,200 chars |

Entries live in `coach_notes` (`store`, `text`, `supersedes_id`, `forgotten_at`). The
limit counts the entries as stored, joined by `\n§\n`. Existing notes became `user`
entries.

## The memory tool

`Coach.Tools.Memory` (`memory`), shared with Claude as `update_memory`:

```json
{"target": "user", "operations": [
  {"action": "add", "content": "Trains before work, around 6:30."},
  {"action": "patch", "old_text": "6:30", "content": "7:00"},
  {"action": "remove", "old_text": "left knee"}
]}
```

- `add` appends; an exact duplicate is not added, and the answer says so.
- `patch` replaces `old_text` inside the one entry that holds it, where it occurs once; a
  whole-entry match wins over entries that contain it. The new entry points at the old one
  (`supersedes_id`), so the conversation shows one "Updated:" line, not a forget and a note.
- `remove` forgets the one entry that holds `old_text`.
- A batch (1–10 operations) is all or nothing (`Memory.Ops.plan/3`, pure). The limit is
  checked on the batch's result, so freeing space and adding go in one batch. A part already
  over its limit (notes kept before the limit existed) takes any batch that does not make it
  larger, so it can always be brought down.
- A patch that leaves an entry as it was changes nothing.
- A rejection is an answer, not an exception: `success: false`, the `error`, the
  `current_entries` and the `usage` (`1,474/2,200`), plus `closest_entries` when nothing
  matched or `matching_entries` when several did.
- Content is blocked when it reads as instructions to the model, a credential, an SSH key
  or invisible characters, or names an internal id (`six_count`).

## How the coach reads it

- **Frozen snapshot.** `Memory.snapshot/1` renders both parts as Hermes does, a header with
  the usage between `═` rules and the entries separated by `§`. `AgentPrompt.messages/5`
  puts it in the second system message, taken when a turn starts. A write inside the turn
  lands at once and shows in the tool's answer, and in the prompt from the next turn.
- **Guidance.** `Memory.guidance/0` says what to keep (preferences, corrections, schedule
  and body changes, agreements) and what to skip (results, what is only true today, what is
  vague), to patch rather than add a second entry, to merge past 80% full, and never to
  mention the memory to the athlete.
- **Claude** reads the same snapshot as `memory` in `get_coach_context`, and the parts with
  their entries and usage through `list_memory`.

## Who writes it

- **The coach, as it talks**, with the memory tool on the Coach page.
- **A background review** (`MemoryJob`), as Hermes runs one after turns: after a session
  with feedback, and after an exchange in which the coach wrote nothing. The model returns
  operations with a target each; each part's batch is applied as the tool would, in the order
  the parts first appear. A rejection goes back once with its reason, a fresh snapshot (so a
  part already written reads as written) and an ask for the rejected part only.
- **Claude**, through `update_memory`.
- **The owner** removes an entry from the memory sheet on Coach.

## What the athlete sees

- In the conversation, a quiet line per change: "Noted:", "Updated:", "Forgot:".
- On Coach, a bookmark icon beside the coach's note (only while there is something to
  remember) opens a sheet with both parts, Profile then Notes, how full each is, and a remove
  button per entry. Removing the last entry closes the sheet and takes the icon with it.
