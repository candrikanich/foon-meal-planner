# M2 Family Loop — train plan (draft, for Chris)

Goal: the rest of the family takes part without being chased.
- **Requests in:** ideas and requests come in from everyone.
- **Ratings back:** dinners get confirmed and rated, so the plan learns what this family likes.
- **Shared cooking:** cooking and jobs are shared.
- **Light touch:** a few well-timed nudges.

The spec's success test for this phase is the mission test. Does it make it easier for more people to contribute, or lighten the planner's load?

## Where M1 leaves us
- **Working:** the Sunday flow works end to end on the local stack.
- **Not yet on phones:** M1 can't reach TestFlight until #37 (hosted Supabase) is decided. M2 can start without it, because most of it is data, UI and pure logic.
- **Push is different:** Apple push notifications need the hosted project and an APNs key, so the plan delivers every feature **in-app first** and adds push in a later car.
- **Already done:**
  - tap low/out on any item, and the quick list's "for tonight" urgency (#44, partly);
  - prep steps on meals, with the first one as a DayCard badge (#45, partly);
  - export and delete household (#47, partly).

## Cars (in dependency order)
| Car | Tickets | Notes |
| --- | --- | --- |
| 1. Dinner loop data | #42 part 1: meal logs and reactions | The heart of M2: everything learns from it (see below). |
| 2. Credit and cooking | #46 cook credit, Thanks chef, serving notes, cook mode | Builds on car 1's logs. Cook mode is pure UI: one step per screen, timers, screen awake. |
| 3. Ideas in | #38 Ideas inbox; #39 Share Sheet extension | #38 brings back #23's "requests waiting" and #21's "save as an idea". #39 is a new app-extension target, so it needs your device to try. |
| 4. Smarter planning | #54 seasonal and variety; #49 household shapes and food rules; #55 equipment and start-cooking time; #53 double it and freezer stash; #52 vacation and season templates | Mostly pure Swift in `Core/Planning` with seeded tests, so they can run as **parallel worker agents** in worktrees, each reviewed before its PR. #49's two-seatings piece is data model only, per the AC. |
| 5. Family tab | #47 remaining parts; #50 claim a night and dinner jobs; #57 change history and undo | #47's notification presets wait for car 6. Claims feed cook credit (car 2). |
| 6. Notifications | #40 infrastructure, then #41 day-of check-in, #45 prep reminders, #44 urgent items and pivots, #43 tonight poll, #51 heading to the store, #42 part 2: the notification card | **Blocked on #37 and an APNs key.** Each feature gets its in-app version in its own car first; this car adds the pushes, budgets, quiet hours and ignore handling. #42 part 2 is the rich notification card (a content extension). |
| 7. Recap | #56 family stats card | Needs cars 1–5 for real numbers. |

### Car 1 detail: #42 part 1
- **Database:**
  - `meal_logs` holds one confirmed dinner per night: what was eaten, who cooked, and leftovers yes/no.
  - `reactions` holds one per member per log: favorite, good, not_for_me, tired_of_it.
  - RLS and pgTAP as usual.
  - Reactions can be changed for 24 hours, then they lock.
  - A night left unconfirmed overnight is saved as an *unverified* log.
- **App:**
  - a "How was dinner?" card on This Week the next day: the missed-prompt card, in-app instead of a push;
  - one-tap reactions for the dish, never the cook;
  - Wasn't home, and We had something else (a mini swap);
  - pass-the-phone mode at the table.
- **What it feeds:**
  - the dislike rule: one not_for_me skips that dish when that member is home; two or more retire it;
  - favorites in Build my week;
  - library history from logs instead of approved plans;
  - the Favorites chip and the Family favorites sort;
  - verdicts on meal detail (the carry-over noted on #42).
- **Split:** this is big, so it likely becomes 2–3 PRs: the data and RLS; the confirm card and reactions; the algorithm and library wiring.

## Not in M2 (proposed)
- **#48 Resend email:** needs a sending domain (the same one as #34 and #85) and a Resend account. → **External TestFlight** milestone.
- **#36 metrics dashboard:** needs #28's analytics first, and real households. → after external TestFlight.

## Decisions needed
1. **How notifications get delivered.** The spec says APNs from scheduled Edge Functions for everything. My recommendation is a hybrid:
   - **On the device (local notifications):** reminders tied to the device owner's own plan and clock, scheduled from the offline cache. That's prep reminders, the day-of check-in, the after-dinner prompt, and Time to plan. They work offline and need no server timezone logic. Each member's budget and quiet hours apply on their own device.
   - **Server push (APNs):** anything another person triggers: Plan's set, an urgent list item, new requests, claims, the tonight poll, heading to the store, and your request made the plan.
   - **Logging:** `notification_log` still records what was sent and what was answered, for ignore handling.
   - The catch is two delivery paths instead of one. Your call; it changes car 6's design and the spec's Notifications section.
2. **Order.** Data loop → credit → ideas → planning → Family → notifications → recap. The alternative is notifications earlier, once #37 is unblocked, because the after-dinner prompt works much better as a push than as a next-day card. Fine to start with car 1 either way.
3. **Move #48 and #36 out of M2**, as above?
4. **Share Sheet extension (#39).** It needs a new target, an App Group for the session, and your device for testing (the simulator's share sheet is limited). Keep it in M2, or move it to M3 with the AI recipe capture (#59), which it overlaps?
5. **Cook mode timers.** In-app countdowns only for M2, or local notifications when the app is in the background? Background timers depend on decision 1.

## Working mode (as in M1)
- One ticket (or ticket part) per PR, test first.
- An independent review subagent before each PR, the fixes from it, green CI, then merge. The spec is updated in the same PR.
- Pure-logic tickets (car 4) run as parallel worker agents in worktrees. UI tickets stay serial so you can try each one.
- Product calls go to you in the PR rather than being guessed. Each PR body ends with a "Needs you" section.
