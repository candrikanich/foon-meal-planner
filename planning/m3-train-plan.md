# M3 Wow Layer — train plan

Goal: Foon feels like it knows the family. Dinner shows up where people already look (lock screen, Siri). It rescues a bad night, reads a receipt, notices a busy calendar, and tells the family how they did. AI makes all of it nicer on phones that can run it, and every feature works without it.

The mission test still applies: does it make it easier for more people to contribute, or lighten the planner's load?

## Where M2 leaves us
- **Built:** the family loop on staging, through build 53.
- **Still open in M2:**
  - #41, #43 and #44 need a second family phone;
  - #122 needs a device check of the after-dinner card;
  - #56's recap half waits on #63, so it moves into car 3 here.
- **Already in place for M3:**
  - Vision text recognition (`Core/Share/TextRecognizer`) and the recipe text parser;
  - the App Group, which the share sheet and the after-dinner card already use;
  - BGAppRefresh;
  - backup dinners and the in-stock check (the tonight poll uses them);
  - the family-stats counts from #56.
- **Not there yet:** any Foundation Models, WidgetKit, App Intents or EventKit code. Each of those is a first use.

## Order: code first, then AI on top
Every M3 feature has a non-AI path (see the spec's AI strategy table), so we build that path first and add the AI to it at the end. This is the same move as M2's "in-app first, push later". It means:
- every car ships something a family can use on any phone;
- the AI cars only add to features that already exist and are already tested;
- #58's queue gets designed against real jobs (#59 capture and #60 phrasing), not guesses about them.

## Cars (in dependency order)
| Car | Tickets | Notes |
| --- | --- | --- |
| 1. Where people look | #62 widgets and App Intents | Adds a widget extension target. The app writes a small "tonight" snapshot to the App Group whenever the plan cache changes, and the widget reads that, with no network in the widget. The home and lock screen widgets show tonight's meal, or the quick pick, or "Not planned yet". Intents: What's for dinner, Add *item* to the list (offline, through the existing list queue), and Request a meal (makes an idea). It needs your phone to try, so it goes first while you're testing anyway. |
| 2. Rescue | #60 tonight rescue, code half | A pure function in `Core/Planning`: (minutes, who's home, in-stock backups, leftovers, freezer stash, library) → 3 ideas, seeded. It reuses the poll's in-stock check and the allergy and dislike rules. Entry points: on tonight's DayCard, and from the poll. |
| 3. Recap | #63 weekly recap and tips; #56's recap half | The templated recap: dinners, who cooked, the top dish, a forgotten favorite, and #56's counts. It's in-app first (a This Week card after the week ends); the Engaged-preset push needs the existing local-notification path only. Tip cards are one-time, on first use of the share sheet, store mode, and the AI pick (once car 6 lands), with "Show tips again" in Settings. |
| 4. Calendar | #64 calendar awareness | Off by default. The read-only EventKit permission is asked only when someone turns it on. A pure function maps events in the dinner window to "suggest rushed" for a night. It's a suggestion the planner taps to accept, never a change. Nothing from the calendar is cached, synced or logged, and a pgTAP or a unit test can't prove that, so the review checks it by reading the code. It's per device, so a parent's calendar only helps when that parent plans. |
| 5. Receipts | #61 receipt scanning, photo half | Vision text, then a pure fuzzy matcher from receipt lines to the household's items, which learns from corrections (a small `receipt_aliases` table: household, raw text, item). Confirming marks items in, checks them off the lists, and offers "Keep apples on hand?" for repeats. The **image never leaves the phone** and isn't kept, which meets the spec's "receipt images deleted after parsing" by never storing one. Forwarded email receipts need the inbound email domain (#48/#34), so that half is #237 in External TestFlight, with #48. |
| 6. AI layer | #58 capability check and the AI job queue; then #59 recipe capture and prep steps; then #60's AI phrasing | First a small `Core/AI` service: it checks `SystemLanguageModel.default.availability` and offers guided-generation calls through closures we can stub in tests (the `ReminderCenter` pattern, no protocol). Then the `ai_jobs` table (claim, complete, expire) with RLS and pgTAP. A capable phone runs its own jobs right away and claims others' on app open and in BGAppRefresh. A job no one claims in time falls back to the non-AI result that's already showing. Payloads never include allergy data. #59 structures shared captions, OCR text and recipes into name, ingredients, steps and prep steps, on top of #39's path. #60 gets friendlier wording for its three ideas. |
| 7. Memories | #65 picky-eater wins, dinner memories, yearly recap | "Tried new dishes" per member comes from logs and reactions (a pure count, the same rule as #56's new-dishes stat), with a gentle celebration for trying, not liking. The yearly recap reuses car 3's recap. The photo timeline reads the photo library on the phone only (decision 1). |

### Parallel work
Cars 2, 3, 4 and 5 are mostly pure Swift (rescue scoring, recap stats, calendar mapping, receipt matching). Their core logic can run as **parallel worker agents** in worktrees, each reviewed before its PR, as car 4 did in M2. The UI on top of each stays serial so you can try them one at a time. Car 5 is the only one of them with a migration, so the migration order rule in lessons.md applies to it alone.

### Testing AI
CI's runners and the simulator may not have Apple Intelligence. So:
- the AI service's closures are stubbed in unit tests, which cover parsing the structured output, timeouts and the fallback;
- a real model run is a device check for you, written into each AI PR's "Needs you".

## Also in M3
The spec's Phase 3 build plan lists two items that had no issue. Both are open now:
- **#235 planner engagement view:** the planner's side of #56.
- **#236 onboarding that shows the AI features:** last, after car 6.

## Working mode (as in M1 and M2)
- One ticket (or ticket part) per PR, test first.
- Each PR gets an independent review subagent, the fixes from it, and green CI before it merges. The spec is updated in the same PR.
- New targets (the widget in car 1) and new permissions (EventKit in car 4, Photos in car 7) go in `project.yml`, the privacy manifest, and docs/app-store-submission.md in the same PR.
- Product calls go to you in the PR rather than being guessed. Each PR body ends with a "Needs you" section.
- TestFlight is tagged after each car that changes what you'd try on a phone.

## Decisions (Chris, 2026-11-03)
1. **Dinner photos (1a):** the timeline reads the photo library on the phone only, around dinner on logged nights. Nothing from it is uploaded, stored by Foon or logged, the same as the calendar. The spec's Minimal data rule says so.
2. **#58's queue is built now**, in car 6 as planned, not after AI ships on capable phones.
3. **Forwarded email receipts** move to External TestFlight as #237, with #48's domain. #61 is the photo half.
4. **#235 and #236** are opened, in M3.
5. **Widgets first** (car 1, #62).
