# #11 Local cache and sync skeleton — plan (as built)

## Scope
- **Cached** (SwiftData): the current week's plan and nights (with meal names), open list lines plus the last day's check-offs, and the household's items (names, staples, stock).
- **Offline writes** (store mode first): check off or uncheck, add to a list (merged like `add_to_list`), and tap a staple low or out.
- **Read-only offline for now:** plan edits. Planners edit the week online in M1.

## How it works
- **`SyncService`** (`@MainActor`):
  - `start()` replays anything queued, pulls a snapshot, then re-pulls whenever Realtime reports a list change.
  - The live client also fires once when the subscription is ready, so changes made before that are picked up.
- **A pull replaces the household's cached rows,** then re-applies queued changes on top, so taps the server hasn't seen stay visible.
- **`perform(change)`** applies the change to the cache at once, queues a `PendingChange` (persisted, with an ordered `sequence`), and tries to replay.
- **`OfflineReplay.replay`** is a pure function that sends changes in order:
  - **offline:** stop, and keep this change and everything after it, so nothing overtakes an earlier change;
  - **rejected** (a PostgREST error): drop it, since retrying can't help;
  - **unexplained:** stop and count an attempt; after 10 attempts the change is dropped so the queue can't jam.
- **Realtime payloads are ignored;** a re-pull is the source of truth. That also sidesteps Realtime's unfiltered delete events (#6).
- **Signing out wipes the cache and the queue,** so the next person on the device never sees another household's data.

## Hardening from review
- **One serialized runner** for every replay and pull: nothing is sent twice or out of order, and an older snapshot can't wipe a change just sent.
- **`add_to_list` takes the device's line id,** so a check-off on a line added offline hits the right row. If the server merges into an existing line, queued changes are re-pointed to it.
- **Sync triggers:** Realtime (lists *and* items), the network coming back (`NWPathMonitor`), and the app returning to the foreground.
- **Errors by code:** only true refusals (SQLSTATE 22, 23, 42, P0 and PGRST1xx/2xx) are dropped. Database-unavailable, gateway and expired-token errors retry.
- **One window on Mac, one scene on iPad,** and a unique Realtime topic per subscription.

## Later
- M1 This Week and Lists screens read `CachedNight`, `CachedListItem` and `CachedItem`, and call `SyncService.perform`.
- Offline plan edits, if store-mode feedback asks for them.
