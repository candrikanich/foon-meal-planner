# M3 car 3a: the weekly recap (#63 recap, #56 recap half)

Branch `feat/63-weekly-recap`. Tip cards (#63's other criteria) are a later PR.

## What it is

A card at the top of This Week, for everyone (kids too), about the week that just ended. It shows from the day after
that week ends for 3 days (household clock), and each device can dismiss it. Engaged people also get one local
notification at 10:00 the day after the week ends.

## Which week

The week before the current one (by the household's week start), when today is within 3 days of its end. With 7-day
weeks and a 3-day window, "the most recent approved week whose last night is before today" is always that one. No card
when it wasn't approved, the household was away all 7 days, or nothing was logged on its approved nights.

## Lines, each only when there's something to say

1. Dinners planned together (`FamilyStats.lines` first line, for weekStart...weekEnd).
2. Thanks to whoever cooked: first names in the order they first cooked that week. No counts, no ranking. Quick picks
   aren't cooking. Removed members are left out.
3. Hit of the week: the logged dish with the most favorite + good reactions that week. Tie goes to the latest night, then
   the meal id. None without a reaction. Removed members and people who eat separately don't count.
4. A favorite you haven't had in a while: someone's current verdict is favorite (`meal_verdicts`), last made
   (`meal_history`) 42+ days before the week's last night, status active or trial (not archived, not retired by the
   dislike rule), and not snoozed on any day the card shows (nobody's current verdict is tired of it within 21 days of
   the day after the week). Most fans first, then the longest gap, then the meal id.
5. The rest of #56's counts for the week, and the time-saved estimate with its footnote.

## Data

`public.week_recap(target_household, from_date, to_date) returns json`, security invoker, read-only, stable:
`{logged, cooks[], top_dish {meal_id,name} | null, forgotten_favorite {meal_id,name} | null}`. Row-level security means
another household gets `{0, [], null, null}`. pgTAP: `supabase/tests/database/65_week_recap.test.sql`.
Family stats come from the existing `family_stats` for the same dates.

## Swift

- `Core/Family/WeekRecap.swift`: `WeekRecapFacts` (decoded), `WeekRecap` (pure: which week, the lines, the note).
- `HouseholdClient.weekRecap`; `Features/Week/WeekRecapSection.swift` loads it with `familyStats` and shows the card;
  dismissal in `@AppStorage("foon.dismissedRecaps")`, keyed by household and week start.
- Push: `ReminderKind.weeklyRecap` (`weekly_recap`, already in `notification_log`'s type check), Engaged only via
  `ReminderRules`. `NotificationPlanner.weeklyRecap()` at 10:00 the day after an approved, not-all-away week with at
  least one logged night as of the read. Quiet hours move it to their end; last in the budget; no follow-up. Fixed words
  "Your week of dinners is ready." / "Tap to see it."; tap opens This Week.
- The reminder snapshot only held this week and next, so on the morning the recap goes out, the week it's about had
  dropped out and a replan would call it off. The snapshot gains `lastWeek` (read in the same query, kept apart from
  `weeks` so nightly prompts, the ignore count and the roundup don't change).

## Unresolved questions

- 30 minutes saved per week and 42 days for "forgotten" are defaults to revisit with founding families.
- The recap names a dish from the family's library in the app only; the notification never does.
