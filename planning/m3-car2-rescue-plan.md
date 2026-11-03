# M3 car 2: Tonight rescue (#60), code half

The AI phrasing waits for car 6. This car needs no migration and no new RPC.

## Defaults taken (Chris said "keep rolling"; each follows the spec, and the PR lists them)
1. **Allergies:** flagged and ranked, never filtered (spec "Flag, don't filter").
2. **Leftovers:** from the last 3 days. A later logged Leftovers dinner means they're gone.
3. **Freezer under a 30-minute budget:** moved down the list, not dropped. Counts as "around 30".
4. **Time choices:** 20, 30 or 45 minutes. Starts at 20.
5. **Trial (new) dishes:** never offered on a rescue night.
6. **Who chooses:** planners choose. Everyone else sees the ideas and can "Ask the family" (starts the tonight poll).
7. **Choosing leftovers:** a plain Leftovers quick pick that names no dish (spec #157).
8. **Repeat window:** applies to quick dishes, as in Swap.

## Core: `Foon/Core/Planning/TonightRescue.swift`
- **Inputs:** minutes, tonight's night, the week, `PlanningInputs`, the freezer, dinner logs, stock and allergies. Returns exactly 3 ideas, seeded.
- **Pools, in this order:**
  1. Leftovers.
  2. Freezer (`FreezerStash.offers`, one per dish).
  3. Backups (`PollRules.backupDinners`).
  4. Quick library dishes (`BuildMyWeek.suggestions` over a pre-filtered list: time fits, no lead hours or thaw, nothing marked out, equipment, not trial).
- **Picking:**
  - First round: one from each pool. Second round: more backups and quick dishes.
  - Fill any gap with Takeout, then Freezer raid, then Fend for yourselves.
  - Tonight's current meal and quick pick are never offered.
- **Each idea has:** a why-line, its minutes (marked when estimated), allergy flags, `swapChoice` and `pollChoice`.
- `StartCooking.minutes(for:)` is exposed; `nudge` uses it.
- `PollRules.isInStock` is shared by backups and quick dishes.

## Choosing
- Goes through `WeekStore.swap` after the `DoubleIt.changeWarning` confirm, sharing the poll's plan/apply flow.
- Freezer ideas use `use_freezer_item`.

## UI
- **DayCard:** `rescue` action, "What can we make?", tonight only, for everyone.
- **NightDetailView:** the same button.
- **RescueSheet:** time picker, who's home, 3 rows, More ideas, and Ask the family (`StartPollSheet` with the ideas pre-selected).
- **Poll result:** when nobody voted, it offers the rescue.
- **DinnerStore:** logs load from `min(today-3, 1st of month)`.

## Tests
`FoonTests/TonightRescueTests.swift`, written first. It covers the design's 20 cases: count and fillers, seed, kind order, time, dislikes and snoozes, stock, allergies, food rules, leftovers, freezer, equipment and trial, on-hand weight, choice mapping, `offers`, and the `StartCooking` pin.

## Spec
- Add a "Tonight rescue (#60)" paragraph after the Tonight poll.
- Day cards gain the button.
- Note that the Swap leftovers list is only partly built, and "backup cooked → used" is still not built.
