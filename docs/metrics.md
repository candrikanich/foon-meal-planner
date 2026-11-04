# Internal metrics

Whether Foon shares the load, measured from data Supabase already has (#36). There's no analytics SDK, no event tracking, and no column added for this: every number comes from tables the app already writes. The product side is in [spec.md → Success metrics: internal](spec.md).

## Running it

In the Supabase dashboard, open the SQL editor (it runs as `postgres`) and run:

```sql
select jsonb_pretty(internal.metrics('2026-11-02', '2026-12-28'));
```

One row per week, for a spreadsheet:

```sql
select w.*
from jsonb_to_recordset(internal.metrics('2026-11-02', '2026-12-28') -> 'weeks') as w (
  week date, iso_week text, households int, active_households int, plans_approved int,
  dinners int, shared_dinners int, north_star numeric, contributors_per_household numeric,
  after_dinner_response_rate numeric, signups int, onboarding_completion numeric, first_plan_rate numeric,
  median_hours_to_first_plan numeric, retention_w1 numeric, retention_w4 numeric,
  shopping_trips int, trial_to_paid numeric);
```

The two dates can be any day: each is moved back to its week's Monday, and both weeks are included. Weeks are ISO weeks, Monday to Sunday.

Only the dashboard (`postgres`) and `service_role` can run it. The function lives in the `internal` schema, which PostgREST doesn't expose (`supabase/config.toml` → `[api] schemas`; on the hosted project, keep `internal` out of Settings → API → Exposed schemas), and execute on it is revoked from `public`, `anon` and `authenticated`, so no app user can call it.

## What it never shows

- No household or member ids, names, dish names, or any row about one household. Every number is pooled across households.
- **Small cells are hidden:** any number built from fewer than 5 households is `null`, never a small count (k-anonymity, k = 5, given as `min_households` in the output). A week with no households doing something is `null` too, not 0. The running total `households` is also null under 10 and otherwise rounded down to the nearest 10, because the difference between two weeks' exact totals would give away a week's suppressed signups.
- Sample families (made with "Load a sample family") aren't counted.

## What each number means

Shared rules: a **planner** is a member whose role is planner, or whose account owns the household (the same rule as `is_household_planner`); it's the role as it stands today, since roles aren't kept as history. **Days are the household's**: a night's date is already its household day, and a timestamp (a request, a sign-up) is read in the household's time zone, New York when none is saved. A **dinner** is a logged dinner at the table on a night of an approved week: a dish, leftovers, takeout or a freezer raid, the stats card's "at the table" rule. Eating out and fend for yourselves aren't counted.

Per week (by the night's date or the activity's household day):

| Field | Meaning | Counted over |
| --- | --- | --- |
| `north_star` | `shared_dinners / dinners`: the share of dinners where someone other than a planner pitched in | households with a dinner that week |
| `dinners` | dinners, as above | same |
| `shared_dinners` | dinners where a non-planner asked for what was planned that night (a request planned there), said me too to it, voted in that night's poll, holds a claim on the night (one taken back doesn't count), or cooked its dish (quick picks aren't cooking) | same |
| `contributors_per_household` | median, over those households, of distinct non-planners who contributed to that week's dinners as above or asked for something or said me too that week | same |
| `after_dinner_response_rate` | reactions left on logged dishes, by people marked home that night, divided by the people marked home for those dishes. Removed members and people who eat separately (who don't rate) aren't counted on either side; someone with no attendance row isn't counted | households with a logged dish and someone marked home |
| `plans_approved` | approved plans whose middle day (`week_start + 3`) falls in this week. A plan's week can start on any day, Sunday by default, so it's counted in the ISO week that holds most of its dinners | distinct households with an approved plan in this week, at least 5 |
| `active_households` | households where anyone did something stored that week: added a member, asked, said me too, reacted, voted or started a poll, claimed or released a night, confirmed a dinner, thanked the cook, answered a check-in, made or approved a plan, added a dish, or added or checked off a list line. The overnight job's unconfirmed logs don't count | itself |
| `households` | households signed up by the end of the week, rounded down to the nearest 10 (12 shows as 10). Under 10 it's `null`, since a rounded 0 would read as none | itself, at least 10 |

Per sign-up week (households made that week, by their own day):

| Field | Meaning |
| --- | --- |
| `signups` | households made that week |
| `onboarding_completion` | the share whose onboarding is done (`settings.onboarded` isn't false; households from before onboarding, which have no flag, count as done, as the app reads them) |
| `first_plan_rate` | the share that have approved a plan since, any time |
| `median_hours_to_first_plan` | median hours from making the household to its first approval, among those that have one (`null` under 5 of them). Approval keeps its first time when a plan is sent again |
| `retention_w1` | the share active (as above) in the next week. `null` until that week is over everywhere: the check is against the server's UTC date with a day's margin, so a household behind UTC has finished it too |
| `retention_w4` | the share active four weeks later. `null` until that week is over everywhere, with the same day's margin |

## What's always null, and what it waits on

- `shopping_trips`: a trip lives on the shopper's device until Finish trip and is never stored on the server. Store runs ("Heading to the store") are pruned after a day and aren't trips. Needs the server to keep a finished trip (a time and an item count would do).
- `trial_to_paid`: waits on StoreKit and the household entitlement (#66). `households.subscription_status` holds only the current state, with no history of when a trial started or converted.

## Known limits

- The planner rule uses today's roles, so someone promoted to planner since stops counting as "someone else" for past weeks.
- The response rate counts reactions, not prompts: the notification log that records after-dinner prompts is kept 8 weeks, so it can't support a long history. A reaction from someone who rated without a prompt counts as an answer.
- A dinner with no attendance rows has nobody "marked home", so it adds nothing to the response rate.
