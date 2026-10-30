# M2 Family Loop — train plan

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
| 6. Notifications | #40 infrastructure (both paths), then #41 day-of check-in, #45 prep reminders, #44 urgent items and pivots, #43 tonight poll, #51 heading to the store, #42 part 2: the notification card | Hybrid delivery (decision 1). The on-device reminders can ship before #37. The server pushes need #37 and an APNs key. Budgets, quiet hours and ignore handling cover both paths. #42 part 2 is the rich notification card (a content extension). The claims push (#50) reads open rows in `night_claims` and sends to the household's planners except `entered_by_member_id`; the in-app note is `ClaimNewsSection`. |
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

## Moved out of M2
- **#48 Resend email:** needs a sending domain (the same one as #34 and #85) and a Resend account. Moved to **External TestFlight**.
- **#36 metrics dashboard:** needs #28's analytics, and real households. Moved to after external TestFlight (M4 Launch).

## Decisions (Chris, 2026-10-28)
1. **Notifications are hybrid.**
   - **On the device:** local notifications for reminders tied to a person's own plan and clock: prep reminders, the day-of check-in, the after-dinner prompt, Time to plan, and cook-mode timers. They're scheduled from the offline cache, with budgets and quiet hours applied on each member's device.
   - **Server push:** APNs from Edge Functions only for things another person triggers: Plan's set, urgent items, new requests, claims, the tonight poll, heading to the store, and your request made the plan.
   - **Log:** `notification_log` covers both paths.
   - The spec's Notifications and Technical architecture sections are updated to match.
   - So car 6's on-device half doesn't need #37 or an APNs key. Only the server-push half waits for them.
2. **Order:** in-app first. Data loop → credit → ideas → planning → Family → notifications → recap.
3. **#48 and #36 move out of M2**, as above.
4. **#39 stays in M2.**
   - Links and plain text are the bulk of real use.
   - Images and PDFs use Vision text recognition and the existing ingredient parser.
   - The AI part of capture (#59) adds to it in M3.
5. **Cook-mode timers** (decided as part of 1): in-app countdowns, with a local notification when the app is in the background.

## Working mode (as in M1)
- One ticket (or ticket part) per PR, test first.
- An independent review subagent before each PR, the fixes from it, green CI, then merge. The spec is updated in the same PR.
- Pure-logic tickets (car 4) run as parallel worker agents in worktrees. UI tickets stay serial so you can try each one.
- Product calls go to you in the PR rather than being guessed. Each PR body ends with a "Needs you" section.
