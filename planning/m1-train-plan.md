# M1 Sunday Flow — train plan

Goal: an **internal TestFlight** build our family can use for a real Sunday. The flow is onboarding → library → Build my week → swap and approve → weekly list → store mode.

## Cars (in dependency order)
| Car | Tickets | Notes |
| --- | --- | --- |
| 1. Look and words | #15 design system and DayCard; #30 part 1: String Catalog set up and all strings localizable | Everything after builds on these. DayCard previews cover the empty, planned, locked, event and flagged states. |
| 2. Library | #18 library screen, #19 meal detail, #20 quick-add parser, #16 allergy matching, #33 notes, brands and non-food, #32 side dishes | #16 and #20 are pure Swift, so they can run in parallel. #19's photo uses #13's pieces. Drop "Make it safe" and substitutions (the spec says later). |
| 3. The week | #22 week generation and attendance (and the shape of household settings), #24 Build my week, #31 traditions, #30 part 2: planning edge cases, #23 This Week screen, #25 swap sheet | #24 is a pure function with seeded tests. Inputs not built until M2 (ratings, requests) are empty for now. |
| 4. Shopping | #26 approve to weekly list, #27 Lists and store mode | Store mode reads #11's offline cache. |
| 5. Onboarding | #17 onboarding, including the one-question allergy step and "Load a sample family" | Needs cars 2–4. |
| 6. Ship | #37 TestFlight pipeline, #29 account deletion and export, #28 crash reporting | Start #37's Apple-side setup now, in parallel with the rest. |

## Not needed for internal TestFlight
- **#21 recipe link import (an Edge Function):** nice to have, at the end of M1 if time allows. It needs SSRF protection per the spec.
- **#34 landing page, privacy and terms:** before *external* TestFlight, alongside the legal review. Needs a domain (also #85).
- **#35 social handles:** a task for Chris.
- **#36 metrics dashboard:** after real usage, M2 or later.

## Decisions (Chris, 2026-10-26)
- **M1 trimmed:**
  - #34 (landing, privacy, terms) and #85 (universal links) moved to a new **External TestFlight** milestone;
  - #36 (metrics) moved to M2;
  - #35 (social handles) is Chris's;
  - substitutions and "Make it safe" struck from #16 and #19 (the spec says later).
- **Design** comes from the spec (warm palette, DayCard per the spec), reviewed live by Chris and iterated.
- **Pure-logic tickets run as parallel worker agents** in worktrees, each reviewed before its PR.
- **#37:** Chris creates the App Store Connect app record now. A hosted Supabase project (needed for TestFlight on phones) is decided when we reach #37.

## Working mode
- One ticket per PR, test first, with review and fix before each PR, as in M0.
- Pure-logic tickets (#16, #20, #24) can go to worker agents in worktrees in parallel, each reviewed before merge. UI tickets stay serial, with Chris trying each in the Mac or iPhone app.
