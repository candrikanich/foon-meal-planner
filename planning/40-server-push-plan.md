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
- **Car 3:** urgent list item → adults, tonight poll → whoever's home, request made the plan.
- **Car 4:** budgets for server pushes (shared count with local reminders via `notification_log`), new-requests digest.

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

## Unresolved questions

1. Is Push Notifications ticked on the App ID `com.andrikanich.foon`? Adding the entitlement before that breaks
   Xcode Cloud signing. Car 1's server half can land first either way.
2. Words: local reminders never name a person or a dish on the lock screen. A server push is *about* a person
   ("Ben won't be home tonight", "Ben will cook Thursday"). Proposal: name the family member (first name only), never
   the dish. Plan's set needs no name: "This week's dinners are set."
3. Does `APPLE_KEY_ID` on staging hold 73FNGXV868? (Assumed yes.)
