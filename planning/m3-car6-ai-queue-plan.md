# M3 car 6, part 1: AI capability check and the household AI queue (#58)

#59 (recipe structuring) is the first real job kind and comes next; #60's phrasing after it. Not in scope here.

## Shape

1. **`Core/AI/AIService`**: closures for `availability` (`SystemLanguageModel.default.availability`, mapped to our
   `AIAvailability`) and `respond` (one `LanguageModelSession(instructions:)` per call, `respond(to:schema:)`), so tests
   stub both (the `ReminderCenter` pattern, no protocol). `generate(_:instructions:prompt:)` takes a `@Generable` type,
   passes its `generationSchema`, and decodes the `GeneratedContent`. Every call races a timeout (30 s; 20 s in a
   background refresh) in unstructured tasks, so a model that ignores cancellation can't hold the caller; caller
   cancellation ends the wait too. The outcome is `done`, `unavailable`, `timedOut` or `failed`: anything but `done` is
   the non-AI path.
2. **`ai_jobs`** (migration `20261103210000`): household, kind (check-constrained, `echo` only for now), payload jsonb
   (an object, at most 32 KB), status (queued, claimed, done, failed, expired), created_by, claimed_by, claimed_at,
   lease_expires_at, result, error, created_at, updated_at, expires_at (default 3 days).
   - RLS: members read; insert in your own name only; updates go through the guard trigger, which allows only a claim
     (queued, or claimed with a lapsed lease; never past expiry; claimed_by must be the caller), a finish by the member
     holding the claim, or an expiry past `expires_at`. Done, failed, expired are final.
   - Security-invoker RPCs with `search_path = ''`, revoked from public and anon: `submit_ai_job`, `claim_ai_job(kinds,
     only_job)` (`for update skip locked`), `complete_ai_job`, `fail_ai_job`.
   - `expire_ai_jobs()` (definer, cron hourly): marks expired, prunes finished rows 30 days on.
   - `erase_household` and `export_household` redefined from their latest versions (tonight_poll and receipt_aliases).
     Test 30 seeds a job.
   - pgTAP `67_ai_jobs`: another household can't read, claim or finish; claimed once; lapsed lease re-claimed; an
     expired job skipped, even by id; only the claimer finishes; finished stays finished; expiry; export.
3. **`AIJobKind`** enum with a handler table; **`AIJobRequest`** is the only way to build a payload, one struct per kind,
   none with a field for allergies or members (CLAUDE.md rule 4). `AIJobPayloadTests` walks every kind's payload.
4. **`AIJobRunner`**: `submit` (claims and runs its own job right away on a capable device), `drain(limit:)` (claims
   others'). A handler's `.unavailable` writes nothing (the lease lapses for another device); `.failed` fails the job.
   Network errors are swallowed: the non-AI result is already showing.
5. **`AIQueueStore`** (`@Observable`, `@MainActor`) and the `AIQueueRunner` modifier on `RootTabView`: drain up to 5
   and load recent jobs on launch and each foreground. iPhone and iPad: `AIRefresh` BGAppRefresh
   (`com.andrikanich.foon.ai`, project.yml), scheduled on going to the background when the device is capable, drains 1
   job. The Mac claims on launch and foreground only.

## Defaults chosen

- Lease 5 minutes; expiry 3 days; finished jobs pruned after 30 days; payload and result at most 32 KB.
- Model timeout 30 s foreground, 20 s background (iOS gives a refresh about 30 s).
- Foreground drain 5 jobs; background 1; background refresh asked for about hourly.
- Offline submit: not queued (no offline AI queue); the non-AI result stands.

## Verification

Swift Testing first (`AIServiceTests`, `AIJobRunnerTests`, `AIJobPayloadTests`, `AIQueueStoreTests`,
`AIOutcomeJobTests`), then `scripts/test.sh`, the iOS simulator build, `scripts/sync-strings.sh --check`,
`supabase db reset --local` and `supabase test db`.

## Needs a capable device

- A real model run through `AIService.live` (CI and the simulator usually lack Apple Intelligence).
- Whether Foundation Models answers inside a BGAppRefresh task, and within 20 s.
- End to end on staging: insert an `echo` job by hand for the household, open Foon on a capable phone, and see it done.

## Open questions

- Should a timed-out job be failed (as built) or left for another device to retry? Failing avoids a job that's too big
  for the model bouncing between devices for three days.
- Should kids' devices run the family's jobs? As built, any member's capable device does.
- What Foon keeps gets its AI line with #59, when something is actually submitted.
