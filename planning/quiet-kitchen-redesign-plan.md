# Quiet Kitchen redesign: plan

Source: Figma file `j2U7Hc1NyX3rO3cyctOSRO`, Screens page, frames "This Week · Quiet Kitchen" (15:617),
"Meal detail · Quiet Kitchen" (26:654), "Lists · Quiet Kitchen" (29:689), "Library · Quiet Kitchen" (33:742),
"Library · Filters open" (35:778). Branch `feat/quiet-kitchen-redesign` off `main`.

Repo rule is one issue per PR, so each phase below is meant to become its own issue + PR. This branch carries
Phase 1; later phases branch from `main` after it merges (no stacking, see lessons.md).

## What the Figma pass did not address

1. **Things the screens dropped.** The mocks show the happy path only. Current code also has:
   - This Week: recap/news/check-in/poll prompts, busy-calendar row, past nights ("Earlier this week"),
     claim ("I'll cook"), lock/shuffle, "What can we make?" rescue, Approve, Build my week (empty week).
   - Meal detail: hero photo, verdicts, comments, serving notes, goes-with, prep ahead, steps, recipe link,
     Edit/Archive/Plan it.
   - Lists: store-run section, receipt scan/forwarding, autocomplete suggestions, Out vs Low.
   - Library: search catalog matches, Archived filter, Add menu (quick add / link / browse ideas), photos.
   Decision per item: keep (where), move behind More, or drop. Default: keep everything, compact it.
2. **System chrome vs custom header.** Mocks put a prominent button inline with the large title and a
   subtitle under it. Plan: keep the system large title (collapse on scroll, back nav, iPad/Mac) with the
   button in the toolbar and the subtitle via `navigationSubtitle`; don't hand-roll a header.
3. **Tab bar.** Mock is a floating pill bar; iOS 26's system TabView already renders that. Keep system.
4. **Meal detail is new, not a restyle.** There's no night-aware meal screen today: NightDetailView is a
   sheet Form, MealDetailView is library-only. The mock merges them. Needs a design decision on routing
   (push from the card, replacing the sheet) and on where night controls (effort, who's home, lock) live.
5. **Data the mocks assume but the app doesn't have:**
   - Lists meal source ("For Sheet-pan chicken fajitas"): `WeeklyList.Line.forMeals` isn't persisted on
     `CachedListItem` — needs a cache/model change.
   - Library "Filters · N": filtering is single-select today; multi-select is a behaviour change.
   - Library "Nora's favorite" per row: derivable from `reactions.favorites`, not exposed on the entry;
     what shows when 0 or 3 people favorite it is undefined.
   - "Cook 3:00–6:00 PM" range: only a start-cooking sentence exists.
6. **Design bugs to fix in code, not copy:** filter chips text not centred and uneven widths, no sheet grabber;
   ambiguous bare "Favorites" next to "Filters · 1"; Meal detail has 3 ways to add ingredients; low-contrast
   gray effort pills; "Water" addable to a shopping list.
7. **Accessibility the mocks don't show:** Dynamic Type at accessibility sizes (compact two-column night rows
   must stack), VoiceOver for the effort menu and underline tabs, dark mode for every new surface.

## Phases

1. **Design system components (this branch).** `DesignSystem/Components.swift`: card container,
   pill button styles (prominent / tinted), effort menu pill, underline tabs, section header, list-row action.
   Previews in light, dark and AX sizes. No screen changes. Gate: iOS + macOS build, tests, strings check.
2. **Lists restyle** (smallest; data gaps deferred): Shop prominent, subtitle count, Add button, badges,
   staples row. Meal source note waits for its own data issue.
3. **Library restyle**: row layout instead of grid, count, Filters sheet. Multi-select + favorite-member are
   separate issues.
4. **This Week restyle**: hero tonight card + compact rows, effort menu, underline week tabs, labelled
   View meal / Swap / More. Keep claim, lock, rescue, prompts.
5. **Night meal detail**: new pushed screen merging NightDetail + MealDetail; retire the sheet.

## Unresolved questions

1. Headings: the mocks switch titles from SF Pro Rounded to SF Pro. It's one line per token in Theme.swift
   but touches 26 files' look. Adopt it, or keep rounded?
2. Library: keep photos (tiles) or go photo-less rows like the mock?
3. Meal detail: replace the NightDetail sheet with a pushed screen?
4. OK to open GitHub issues for phases 2–5 and the data gaps?
