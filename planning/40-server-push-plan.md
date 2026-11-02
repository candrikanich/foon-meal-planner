# #40 part 2: server push (plan, 2026-11-02)

Spec: docs/spec.md → Notifications → Delivery. Server push is only for things another person triggers:
Plan's set, urgent list items, new requests, claims, the tonight poll, heading to the store, "your request made the plan".
Local reminders (part 1) stay as they are.

Apple side is ready: key 73FNGXV868 ("Foon 2026") has APNs, team-scoped, Sandbox and Production, and is already in
staging as `APPLE_TEAM_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` (Sign in with Apple uses the same key). No new secrets.

## Shape

1. **Device tokens.** `push_devices (id, user_id, member_id, household_id, token, environment sandbox|production,
   updated_at)`. RLS: a user sees and writes only their own rows. `register_push_device(token, environment)` upserts
   by token (a token moving to another account moves with it). Sign-out, account delete, leaving the household, and
   turning reminders off delete the row. pgTAP proves another household (and another member) can't read it.
2. **Outbox.** `push_outbox (id, household_id, member_id, kind, night_id, args jsonb, not_before, created_at,
   sent_at, failed)`. No client access at all. Written only by SECURITY DEFINER code at the moment the event
   happens (e.g. inside `approve_plan`), after `household_away_on` and the preset/opt-in checks. `args` holds only
   what the fixed words need. Quiet hours set `not_before` (9pm–7am everyone, weekday 8am–3pm kids, household zone).
3. **Sender.** Edge Function `send-push`: reads due outbox rows with the service role, signs one ES256 APNs JWT
   (reuses `clientSecret`-style signing, `aud`-less provider token, cached under 50 min), POSTs to
   api.push.apple.com or api.sandbox.push.apple.com by the device's environment, topic `com.andrikanich.foon`.
   410 / BadDeviceToken / Unregistered → delete that device. Writes `notification_log` (channel push).
   Started every minute by pg_cron through pg_net, with the function URL and a shared secret in Vault.
4. **App.** `aps-environment` entitlement (development; App Store export switches it to production), register for
   remote notifications once reminders are on, send the token, tag the environment by build (`#if DEBUG` →
   sandbox). Tapping a push opens the same routes local reminders use. Mac: same entitlement on the Mac target later.

## Cars

- **Car 1:** tokens + outbox + sender + one trigger, **Plan's set** (everyone but the approver, every preset).
  Verify on device: Chris approves on the Mac/iPad, phone buzzes.
- **Car 2 (done, 2026-11-02):** check-in "won't be home tonight" → planners, and claims → planners (both already have
  in-app notes reading the same rows). Migration `20261102180000_push_car2.sql`, pgTAP `54_push_car2.test.sql`.
- **Car 3 (done, 2026-11-02, server half):** urgent list item → adults, tonight poll → whoever's home, request made
  the plan. Migration `20261102190000_push_car3.sql`, pgTAP `55_push_car3.test.sql`. App half: a "list" tap route.
- **Car 4 (server half, 2026-11-02):** budgets for server pushes (shared count with local reminders via
  `notification_log`), new-requests digest. Migration `20261102200000_push_car4.sql`, pgTAP `56_push_car4.test.sql`.
  App half: count your own `channel = 'push'` log rows in the budget, and an "ideas" tap route.

- **#51 Heading to the store (2026-11-02):** `store_runs` + `start_store_run` (any adult, one open run per household,
  10 minutes), push kind `heading_to_store` (already in both kind lists) to everyone else with a device on Engaged, rank
  0 for budgets, route "list". Migration `20261102210000_store_run.sql`, pgTAP `57_store_run.test.sql`.

## Decided (2026-11-02, Chris)

- Words: a server push may name the family member (first name only), never the dish.
- App ID: Push Notifications is on for `com.andrikanich.foon` (saved 2026-11-02, no SSL certificates: token auth with the key).

## Decided for car 2 (2026-11-02)

- New kind `not_home` on both `push_outbox` and `notification_log`. The app never reads log types back, so older apps are
  unaffected.
- `push_outbox` gains `expires_at` (general: a row not sent by then is stale), `about_member_id` (once-only, call-off,
  and removal) and `claim_id`. `claim_push_outbox` also returns `night_id`, `night_date` and `args`.
- Both expire at that night's dinner time (`night_dinner_at`: the night's time, else the household's, else 6pm, on the
  household's clock). A row quiet hours would hold past dinner isn't queued.
- Presets read the household's `notification_preset` only (missing/unknown = Balanced, as the app reads it). Per-member
  presets (#47) aren't consulted yet.
- Recipients exclude the person the news is about and whoever tapped it (passing the phone), plus, for a claim, whoever
  entered it.
- A push already being sent when it's called off still goes (the row is deleted and complete finds nothing).
  The same goes for a row in flight when its subject is removed, leaves, or deletes their account: it still goes out.
- A claim row goes only if it still stands when it's due (`push_outbox_stands`: not released, `can_cook_night`, no quick
  pick, dinner not logged); otherwise it waits until dinner, then is dropped as stale. The cook saying Not home deletes
  it outright. `kick_push_sender` asks the same, so a waiting claim doesn't wake send-push every minute. Rows about a
  night are also stale once `night_dinner_at` (as the night is now) has passed, so moving dinner earlier still ends them.
- send-push fails a row as `no_words` (not `unknown_kind`) when it knows the kind but the name or date is missing.

## Decided for car 3 (2026-11-02)

- The three kinds were already in both kind lists; no constraint change.
- Urgent: `list_items.urgent_by` (no FK, stamped by a before trigger from `my_member_id`, so the app can't set it and a job
  leaves it empty). Only `list = 'quick'`; a weekly line marked tonight doesn't send. Becoming urgent means an insert
  with tonight, or an update whose old row wasn't an urgent quick line, so add_to_list merging "tonight" into an urgent
  line sends nothing. Coalescing is per recipient across adders: while one is waiting, a second adder's line adds nothing,
  and if the first adder's lines then go, the waiting row is called off and the second adder's isn't sent.
- Urgent expiry: `household_dinner_tonight` (tonight's night's `night_dinner_at`, else settings dinner time, else 6pm),
  and `night_id` is set to tonight's night when there is one so a moved dinner time still ends it. Adults only, so adult
  quiet hours.
- Poll: recipients mirror `vote_in_poll` (not removed, not eating separately, not marked out tonight), minus the starter
  and the caller. Call-off on any `closes_at` that moves earlier (close_poll). A poll's push isn't held back once dinner's
  logged; it lasts at most the poll.
- Idea: on a later approval of the same week, ideas not told yet are told; one planned after approval is not (no trigger on
  requests). The requester must have entered it themselves (`entered_by` null counts as theirs).
- Payload for urgent: `{"route": "list"}` only, no other keys. The tonight poll sends `{"route": "dinner"}` (This Week's
  vote card; the night sheet hides an open poll), not the night.
- Review fixes: `push_outbox_stands(kind, claim, request, night)` replaces car 2's two-argument version; an idea's push
  stands only while the request is planned on that night. Urgent skips members away (`status = 'away'` until
  `away_until`). Consent withdrawal (`anonymize_expired_profiles`) deletes urgent and poll rows about the kid, sent too, and
  clears `list_items.urgent_by`; the stamp trigger leaves `urgent_by` alone on updates so retention can clear it.

## Decided for car 4 (2026-11-02, defaults; open questions below)

**Budgets.**
- One budget per person per household week, the device's numbers: kids 2 / 5 / 6, adults 8 / 12 / 16 on Light / Balanced /
  Engaged. The household's `notification_preset` only (per-person presets, #47, aren't read on the server yet). The week is
  the household's (`settings.week_start`, default Sunday) on its clock, the week the push would go out in.
- Counted from `notification_log`: every row for that person in that household with `sent_at` inside the week, either
  channel. Server pushes are already logged on send (`complete_push_outbox`, channel `push`). Device rows count once the
  device has uploaded them; a reminder the device has scheduled but not yet sent isn't counted (no reserving, either way).
- At claim time, before handing anything out, each due row is ranked per person: `plan_set` and `urgent_item` first, then
  `not_home` and `claim`, then `tonight_poll`, then `request_planned` and `new_requests`, then soonest. Rows that would take
  the person past what's left this week end as `failed = 'over_budget'`: never sent, never retried, never logged. It's in
  `failed` because that is the outbox's one "ended without sending" column (stale, called off by time, gave up); every
  rule that skips finished rows already skips it. send-push never sees one, so it isn't a delivery failure.
- A row handed out and not finished (`attempts > 0`, unsent, not failed: a retry waiting, a run still sending, a crashed
  run's hold) counts against what's left, so a new row can't take the same last slot. Only rows that still stand count, and
  the over_budget update rechecks `failed is null and attempts = 0` on the row, so one another run just claimed isn't marked.
- A digest row is a planner's once-a-day mark, so nothing deletes it early: consent withdrawal and
  `members_drop_push_devices` (removal, leaving, a profile claimed) blank `args.name` and `about_member_id` instead. A
  digest sent to someone goes when they're removed (what was sent to them goes with them) and stays only on an account
  change while they're still in the family (their devices go, so an unsent one ends as `no_devices`). A new digest names
  someone only if `push_may_name` (not a kid whose parental consent was withdrawn); otherwise it's count only.
- No kind is exempt. Nothing about allergies or safety is a push, so a budget can't drop one.
- Held for a later week: no. Everything a server push says is about now or a night this week.
- The device: today it counts only what it scheduled itself (`ReminderCache`), so server pushes don't reduce its own budget
  yet. App half: read your own `notification_log` rows with `channel = 'push'` (RLS already lets everyone read their own)
  and add their `sent_at` to `NotificationPlanner.withinBudget`'s count. The device still plans its own reminders first, so
  a busy week can still reach budget + a few pushes on that phone until it next re-plans; the server never goes past.

**New-requests digest.**
- Planners, Engaged only. Once a day per planner at 7:30pm on the household's clock (after dinner, before the 9pm quiet
  hours, outside kids' school hours), if there are new ideas since that planner's last digest (at most the last day, the
  first time). A pg_cron job every 15 minutes queues it between 7:30 and 9pm, once a planner a day.
- New: requests created since then that are still open, not asked for or entered by that planner. Not on an away day.
- Words: "1 new dinner idea." / "2 new dinner ideas.", or with one person "Ben has a new dinner idea." / "Ben has 2 new
  dinner ideas."; "Tap to see it." / "Tap to see them." Never a dish. `args` is `{"count": n}` plus `"name"` when one person.
- Route `{"route": "ideas"}`: the app has no ideas route yet (App half). Expires at 9pm that day.

## Unresolved questions

1. Is Push Notifications ticked on the App ID `com.andrikanich.foon`? Adding the entitlement before that breaks
   Xcode Cloud signing. Car 1's server half can land first either way.
2. Words: local reminders never name a person or a dish on the lock screen. A server push is *about* a person
   ("Ben won't be home tonight", "Ben will cook Thursday"). Proposal: name the family member (first name only), never
   the dish. Plan's set needs no name: "This week's dinners are set."
3. Does `APPLE_KEY_ID` on staging hold 73FNGXV868? (Assumed yes.)
4. Car 4: are 7:30pm and once a day right for the ideas digest? Should Balanced get it too?
5. Car 4: should urgent items and Plan's set be exempt from budgets rather than first in line? Today a person at budget
   misses an urgent item.
6. Car 4: should the server read per-person presets once #47 writes them, so the server and the device agree on a budget?
   Defaulted yes (#47 car 6 part A): `member_preset` reads each person's own, for every preset-dependent push and the budget.
