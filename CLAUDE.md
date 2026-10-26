# Foon — CLAUDE.md

Foon is an iOS family dinner planner. Mission: **take the weight of dinner off one person and share it with the whole family.**

Every feature must pass one test: *does it make it easier for more people to contribute, or lighten the planner's load?* If not, it waits.

Full product spec: [docs/spec.md](docs/spec.md). Starter dishes: [docs/starter-pack.md](docs/starter-pack.md). App Store listing and compliance: [docs/app-store-submission.md](docs/app-store-submission.md). These are exports of the living spec doc; if they disagree with a ticket, ask in the PR rather than guessing.

## Stack

- **Client:** SwiftUI multiplatform app (iPhone, iPad, Mac). Minimum OS: **iOS 26 / macOS 26**.
- **State:** `@Observable` view models + a thin service layer. No TCA, no Combine-heavy patterns.
- **Local cache:** SwiftData for the current week's plan and shopping lists (offline store mode).
- **Backend:** Supabase (Postgres, Auth, Realtime, Edge Functions, Storage) via `supabase-swift`.
- **Auth:** Sign in with Apple only.
- **AI:** Apple Foundation Models (on-device) as an optional helper. Never required.
- **Payments (Phase 4):** StoreKit 2 with server-side household entitlement.

## Repo layout

```
Foon/                  Xcode project (app target, share extension, widget, tests)
  App/                 App entry, navigation, environment
  Features/            One folder per feature (Onboarding, Week, Library, Lists, Ideas, Family)
  Core/                Models, services (Supabase, cache, sync), algorithm, parsers
  DesignSystem/        Colors, typography, DayCard and shared components
FoonTests/             Swift Testing unit tests
supabase/
  migrations/          SQL migrations (supabase CLI), one per change
  functions/           Edge Functions (TypeScript/Deno)
  seed/                Catalog seed (starter pack)
  tests/               pgTAP tests for RLS
```

## Non-negotiable rules

1. **Household tenancy.** Every household-owned table has `household_id` and row-level security. Access goes through `is_household_member(household_id)` / `is_household_planner(household_id)` helpers. No table ships without RLS and a pgTAP test proving another household can't read it.
2. **No secrets in the app.** Only the Supabase URL and anon key live in the client (via xcconfig). Service-role keys only in Edge Functions.
3. **Mostly code, AI as helper.** Planning, scoring, filtering, allergy flags, list building, and parsing are deterministic Swift or SQL with unit tests. AI features must check `SystemLanguageModel.default.availability` and always have a non-AI path.
4. **Minimal data.** First names, avatars, roles, allergies, preferences. No birthdays, phone numbers, location, or photos of people. Allergy data never leaves the device for AI.
5. **Rate the dish, never the cook.** UI copy about reactions always refers to the food.
6. **Never hard-delete user content.** Meals archive; members go "away" or are removed with history kept.
7. **Everything configurable has a sensible default.** Settings are layered: defaults, presets, advanced.

## Domain vocabulary

- **Household** = family account. **Member** = profile (may be unclaimed). Roles: Owner, Planner, Member.
- **Catalog** = shared read-only starter dishes. **Library** = the household's own meals (copied from catalog or added).
- **Plan / night** = one week of nights; each night has attendance, effort (normal, rushed, full, event), and a meal or quick pick.
- **Quick picks:** Leftovers, Takeout, Eat out, Fend for yourselves, Freezer raid.
- **Standing tradition** = a recurring meal on a weekday (Taco Tuesday). **Claim** = a member volunteering to cook a night.
- **Variety, not nutrition:** never add calorie or nutrition tracking; it's a family app with kids.
- **Calendar data** (when enabled) is read on-device only and never uploaded.
- **Reactions:** favorite, good, not_for_me, tired_of_it. Dislike rule: 1 not_for_me = skip nights that member is home; 2+ = retired.
- **Lists:** weekly (from plan), quick (pivots and taps), keep-on-hand items with stock state in/low/out.

## Code conventions

- Swift 6 strict concurrency. Services are `actor`s or `@MainActor` view models.
- One feature per folder; views stay small; logic lives in view models or Core.
- The Build-my-week algorithm is a pure function: `(inputs, seed) -> draft`. Deterministic with a seeded RNG so tests are stable.
- Use Swift Testing (`@Test`) for unit tests; cover the algorithm, parsers, allergy matching, and list merging.
- SwiftUI previews for every new view, with mock data from `Core/Mocks`.
- Accessibility: Dynamic Type and VoiceOver labels on all interactive elements.

## Workflow

- Work comes from GitHub issues, grouped by milestone (Phase 0–4). Plan a train per milestone; worker, review, and verify agents handle tickets; Chris reviews and merges.
- One issue per PR. PR description lists acceptance criteria with checkboxes, and how they were verified.
- Database changes: new migration file, never edit an applied one. Run `supabase db reset` and pgTAP tests locally.
- Definition of done: builds for iOS and macOS, tests pass, RLS tested (if schema), previews render, acceptance criteria met.

## Priority

Speed to a working TestFlight build. Milestone M1 (Sunday flow) is the first internal TestFlight target: onboarding, library, This Week cards, Build my week, swap, approve, shopping list, store mode.
