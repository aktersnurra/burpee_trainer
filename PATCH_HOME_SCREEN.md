Honest read: this Home screen has improved but it's still fighting the principle we landed on — **Home has one job: get the user into a workout fast.** The current layout buries the action and over-indexes on status. Let me work through what's wrong and propose a redesign.

**The problems, in order of severity:**

**1. The dominant element on the screen is a 12-week history grid that mostly shows nothing.** Twelve cells, most showing "—" (no session). This is the first thing the user sees, and it communicates "look at all the weeks you didn't train." It's also retrospective — it belongs on Stats, not Home. Home is forward-looking ("what am I doing today?"). The grid is backward-looking dashboard content.

The grid also competes for the same job as the streak card above it — both communicate "how have you been training over time." Doubled up. One has to go.

**2. The primary action ("Run a plan") is generic, not specific.** Tapping it presumably routes to Workouts to pick a plan. That's a wasted step. The user opened the app to train; Home should already know what they're most likely to run and let them start it in one tap.

**3. The streak card is doing three things at once: streak, this-week progress, and level.** Three pieces of equal-weight information means none of them is the headline. The user's eye lands and bounces.

**4. The vertical hierarchy is upside-down.** Status takes ~70% of the screen, action takes ~15%, log-session ~10%, rest is empty space below. For an action-first screen, this is inverted.

**What Home should look like:**

```
┌─────────────────────────────────────────────────┐
│   [Home]   [Workouts]   [Stats]                 │
└─────────────────────────────────────────────────┘


  This week                                    
  
   0 / 80 min        ·  ◯  ·  ·  ·  ·  ·       
  ───────────         M  T  W  T  F  S  S      
  
  2 week streak                       LEVEL 2  


┌─────────────────────────────────────────────────┐
│                                                 │
│   Pick up where you left off                    │
│                                                 │
│   150 6-Counts sets of 15                       │
│   150 burpees · 20 min · Level 1D               │
│                                                 │
│   ┌─────────────────────────────────────────┐   │
│   │              ▶  Start                   │   │
│   └─────────────────────────────────────────┘   │
│                                                 │
│   Pick another workout →                        │
│                                                 │
└─────────────────────────────────────────────────┘


  + Log a past session

```

Three things, in order of prominence:

1. **A compact status strip** (one line, no card chrome). Current week minutes + day strip + streak count + level. Glanceable, no decoration.
2. **A specific workout card with a big start button** — the dominant element on the screen. One tap into the session runner.
3. **A small log-session link** below, secondary affordance.

**Why this works:**

**The status strip becomes ambient context, not the focus.** It's there if the user wants to glance at it, but it's not claiming the headline. No card border, no big numbers, no grid. Just enough information to remind the user where they are this week. The level chip sits inline as part of the same status row — no separate card.

**The workout card is now the visual center of gravity.** It's the largest element, the brightest button, the natural place the eye lands. And critically, it's *specific* — it suggests an actual workout with all the metadata the user needs to decide "yes, do this one" or "no, give me something else."

**"Pick another workout →" is the escape hatch.** When the suggested workout isn't what the user wants, this link takes them to the Workouts tab. But the *default* path — tap the big Start button — is one tap, zero decisions. That's the principle in action.

**The log-session affordance is small and below the fold of attention.** It's there for the user who needs it ("I trained yesterday and forgot to log it") but doesn't compete with the primary "start a workout" action.

**What goes in the "suggested workout" slot:**

In order of preference:

1. *The user's most-recently-run workout.* Highest hit rate — people repeat workouts. Label: "Pick up where you left off."
2. *Today's scheduled workout*, if scheduling ever exists. Label: "Today's plan."
3. *A workout the Bayesian recommender suggests.* Label: "Suggested for today."
4. *First-launch fallback*: a generic "Run a plan" button when there are no plans yet. The new-user state.

The card label changes based on which case applies, so the user understands *why* this specific workout is being suggested.

**One important consequence: the 12-week grid moves to Stats.** It's good content; it's in the wrong place. On Stats, surrounded by other historical data (trend charts, session history), it makes sense as one view among several. On Home, it's a dashboard imposed on an action screen.

**A few specifics on the status strip:**

```
0 / 80 min        ·  ◯  ·  ·  ·  ·  ·       
                  M  T  W  T  F  S  S      

2 week streak                       LEVEL 2  
```

- *Minutes/target* on the left, *day strip* on the right. Both fit on one line.
- *Day strip* gets the today-marker (outlined circle on T), filled dots for trained days, empty for untrained. Same component as the Stats screen.
- *Streak and level* on the second line, far apart. Streak left-aligned (it's training-related), level right-aligned (it's identity-related).
- No card border, no panel background. Just text on the page. Lighter visual weight than the workout card below.

**A subtle but important thing:** the absence of a card border around the status strip is what lets the workout card dominate. If both are in cards, they compete. If only the workout card has card chrome, the eye knows where the primary action is.

**Why this beats the current design:**

1. *Action-first.* The user can train in one tap from opening the app. Currently it's a minimum of 2-3 taps (Home → Run a plan → pick from Workouts → start).
2. *Less visual noise.* No 12-cell grid, no triple-purpose streak card, no parallel CTAs at equal weight.
3. *Empty space is now intentional.* The screen doesn't try to fill the viewport with dashboard content. It does one thing well, and the rest of the screen is just... space.
4. *Honest about what Home is.* It's a launcher, not a dashboard. Stats is for dashboard content. Workouts is for browsing. Home is for "start now."

**The harder question this surfaces:**

Once you build this, you may find that Home is so simple it doesn't justify being its own tab. If the answer to "what's on Home" is "a status strip and one workout card," that's potentially just a launcher screen that could *be* the first thing inside Workouts, or could open directly to the suggested workout in the runner.

Two evolutionary paths:

1. *Home stays as a separate tab.* Default landing surface. Lightweight on purpose.
2. *Home gets absorbed into Workouts.* Workouts opens to a "suggested first" view with the rest of the list below. No separate Home tab. Drops the nav to 2 tabs (Workouts, Stats).

You don't have to decide this now. Start with Home as its own tab — it's the lower-risk option, and you can always merge later if usage data shows Home is just a passthrough. But it's worth knowing the option exists, because if your Home really is just "a launcher to one suggested workout," merging it into Workouts is not crazy.

**One final thought on the desktop screenshot you shared:**

The top nav (Home / Workouts / Stats / logout icon) is good — labeled, clear, active state visible. This is the right pattern. On mobile this collapses to the bottom tab bar from the earlier discussion; on desktop/wide layouts it works well at the top.

The logout icon on the far right of the nav is fine where it is — it's an escape hatch, not a destination, and it doesn't pretend to be a tab. Settings genuinely doesn't need a tab.

**Prioritized fix list for Home:**

1. Replace "Run a plan" generic button with a specific suggested-workout card with big start button.
2. Move the 12-week grid to Stats; replace with a one-line status strip.
3. Consolidate the streak/this-week/level info into the status strip.
4. Demote "Log a session" to a small link.

After these four changes, Home does its job in roughly one-third the vertical space and gets the user training in one tap.
