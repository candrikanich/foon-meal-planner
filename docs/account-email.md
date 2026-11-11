# Account email: setup and checks (#48)

What these emails say and when they go is in [spec.md](spec.md) (Email → Account email), the legal side in
[legal/privacy.md](legal/privacy.md) and [legal/retention.md](legal/retention.md). This is what to configure, how to
turn it on, and what to check. The function is `supabase/functions/account-email`, the deletion receipt is sent by
`supabase/functions/delete-account`, and the database side is `supabase/migrations/20261121000000_account_email.sql`.

**Nothing sends until all of this is done and the flag is on.** The migration ships with
`app_config.account_email_enabled = false`: welcome and subscription rows queue, nothing is claimed or sent, and
`delete-account` sends no receipt.

## Configure

| Where | Name | Notes |
| --- | --- | --- |
| Edge Function secret | `RESEND_API_KEY` | Already set for the waitlist and consent emails; the same key sends these |
| Edge Function secret | `ACCOUNT_EMAIL_FROM` | `Foon <info@getfoon.com>`. Must be on a domain verified in Resend. Without it (or the key) `account-email` answers 503 `email_off` and claims nothing, and `delete-account` sends no receipt |
| Edge Function secret | `ACCOUNT_EMAIL_CRON_SECRET` | A long random string, the same value as Vault's `account_email_cron_secret`. Unset, every run answers 401 |
| Edge Function secret | `ACCOUNT_EMAIL_SITE_URL` | Optional. Defaults to `https://getfoon.com`. Used for the welcome's privacy link, the weekly email's "Open Foon" link, and where an unsubscribe link redirects (`/email/unsubscribe`); its origin may also POST unsubscribes from a browser (alongside getfoon.com, www and localhost) |
| Edge Function secret | `EMAIL_POSTAL_ADDRESS` | The postal address for marketing email (founding-family updates), lines split by `;`, e.g. `PO Box 1; Town, OH 44000`. Unset, no founding update goes: the Action's calls answer 503 `no_postal_address` and queued rows are given up as `no_postal_address`. The weekly plan email uses the address in `_shared/resend.ts` |
| Edge Function secret | `FOUNDING_UPDATES_SECRET` | A long random string, the same value as the GitHub environment secret of that name. Unset, the Action's calls answer 401 |
| Edge Function secret | `FOUNDING_UPDATES_PREVIEW_TO` | Where a preview goes (Chris's own address). Unset, a preview answers 503 `no_preview_address` |
| Edge Function (built in) | `SUPABASE_ANON_KEY` | Set by Supabase. The invite door (`?invite=1`, #48 PR B) calls `reserve_invite_email` as the parent with it and their JWT |
| Edge Function (built in) | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Set by Supabase. The service role key also signs the opt-in emails' unsubscribe links (as the waitlist's), so rotating it breaks unsubscribing from emails already sent: the footer link and the mail app's one-click button carry the same signed URL, and both fail. Only Family → Email still turns them off; emails sent after the rotation work |
| GitHub environments `staging` and `production` | `FOUNDING_UPDATES_SECRET` | The same value as that project's Edge secret. Create the `staging` environment if it doesn't exist; `production`'s required reviewer applies to the Action |
| Vault (database) | `account_email_function_url` | `https://<project-ref>.supabase.co/functions/v1/account-email`. `kick_account_email()` POSTs to it |
| Vault (database) | `account_email_cron_secret` | Same value as `ACCOUNT_EMAIL_CRON_SECRET`; sent in the `x-account-email-secret` header. Without both Vault secrets the cron does nothing, silently |

Set the secrets on staging and production (Supabase → Edge Functions → Secrets, or
`supabase secrets set ACCOUNT_EMAIL_FROM='Foon <info@getfoon.com>' --project-ref <ref>`). Deploys need nothing new:
both deploy workflows deploy every function, and `config.toml` turns the gateway's JWT check off for `account-email`
(pg_cron sends the shared secret instead, checked in constant time).

Vault secrets (SQL editor, once per project; never commit the values):

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/account-email', 'account_email_function_url');
select vault.create_secret('<the same value as ACCOUNT_EMAIL_CRON_SECRET>', 'account_email_cron_secret');
```

Apple's private email relay: `getfoon.com` and `info@getfoon.com` must be registered (Apple Developer → Sign in with
Apple for Email Communication), as for consent email; see [parental-consent.md](parental-consent.md). Without it,
email to Hide My Email addresses bounces.

## Turn it on

Only once the secrets above are set on that project, the relay is registered, and a privacy policy version that lists
these emails is in force (a later PR for #48). Staging first:

```sql
update public.app_config set account_email_enabled = true;
```

Turning it on doesn't send a backlog: rows more than 2 days old are dropped as `stale` on the first claim. To turn it
off again, set it to `false`; rows keep queueing and nothing goes.

## How it runs

- Triggers queue rows in `email_outbox`: `households_queue_welcome_email` (a new household that isn't a sample) and
  `household_subscriptions_queue_email` (SUBSCRIBED, DID_RENEW, DID_FAIL_TO_RENEW, renewal turned off or back on,
  DID_CHANGE_RENEWAL_PREF, REFUND and REVOKE, GRACE_PERIOD_EXPIRED (a billing problem again, not the end) and EXPIRED; kinds `subscription_started`,
  `_renewed`, `_billing_problem`, `_ending`, `_renewal_on`, `_plan_changed`, `_refunded`, `_ended`, added in
  `20261123000000_account_email_subscription_events.sql`). Each event queues once
  (`unique (kind, dedupe_key)`). A subscription row's payload has the product id, trial flag, end date, the household's
  time zone (America/New_York without a valid one; the email's dates use it) and `billing_enforced` at that moment
  (the ended and refunded emails say nothing changes during the beta, or that Foon is view-only once billing is on). By
  kind the payload adds `grace` (billing problem in a grace period; `ends_at` is when access continues until),
  `revoked` (refunded because Family Sharing ended) and, for a plan change, the new plan in `product_id` and
  `immediate` (an upgrade). Ending, ended, refunded and billing problem are skipped while another of the household's
  subscriptions still grants access. A plan change needs the plan Apple says the subscription renews as, which
  `app-store-notifications` passes to `apply_subscription_notification` as `next_product_id` and
  `subscription_events` keeps.
- pg_cron `kick-account-email` (every 5 minutes) calls `kick_account_email()`, which POSTs to the function only when
  the flag is on, something is due, and both Vault secrets are set.
- The function claims up to 50 rows at a time for at most 40 seconds (`claim_account_emails`). The claim drops rows
  that mustn't go (`stale`, `gave_up`, `not_adult`: the recipient isn't an adult in that household any more,
  `no_address`: no verified Apple email), holds the rest for 10 minutes, and stops at 200 sent or in flight in the
  last hour. Each is sent through Resend with `Idempotency-Key: account-email/<row id>` (so a send that went out but
  wasn't recorded isn't sent again when the row is retried within Resend's 24-hour window), then `account_email_mark_sent`, or `account_email_release` with an error code
  (`resend_<status>`, `timeout`, `send_failed`) to retry after 10, 20, 30, 40 minutes; after 5 tries it's given up.
  A row it can't write (`no_words`) is given up at once.
- `prune-email-outbox` (daily, 03:47 UTC) deletes rows 30 days after they were queued. A household's rows go with it,
  and an account's with the account.
- Deletion receipts aren't queued. `delete-account` calls `deletion_receipt_address(account)` before deleting (null
  while the flag is off, for a kid, for an account in no household, or without a verified Apple email), and sends
  after the deletion has fully gone through. A failure is logged as `deletion receipt not sent (<code>)` and never
  changes the deletion's answer.

Logs carry row ids and error codes only, never an address.

## Opt-in emails (PR C)

Database side: `supabase/migrations/20261123900000_email_opt_in_agreement_kinds.sql` (the two agreement kinds, on
their own because an enum value can't be used in the transaction that adds it) and
`supabase/migrations/20261124000000_account_email_opt_in.sql`.

- An adult turns them on in Family → Email (`set_email_preference`, which logs the agreement). The section shows only
  while `account_email_enabled` is on, and opting in is refused while it's off.
- **Weekly plan email:** `plans_queue_weekly_plan_email` queues a `weekly_plan` row for each opted-in adult the first
  time a week is approved (dedupe `plan:user`, so once per week per person; not for a week that's over), 10 minutes
  out. The function reads the week when it sends (`account_email_weekly_plan`); a week no longer approved is given up
  as `not_approved`.
- **Founding-family updates:** the "Founding update" Action (`.github/workflows/founding-update.yml`) POSTs to
  `account-email?founding=preview|send` with `x-founding-updates-secret`. Send queues `founding_update` rows through
  `queue_founding_update` (409 `email_off` while the flag is off; the same subject and body again queues nothing).
- **Unsubscribe:** each email's link is `account-email?unsubscribe=<kind>.<account>.<signature>`. A GET redirects to
  getfoon.com/email/unsubscribe (the site builds its POST URL from `NUXT_PUBLIC_WAITLIST_URL`, so it needs no new
  setting); a POST (the page's button, or the mail app's one-click) runs `email_unsubscribe`. Turning one off, either
  way, drops that email's waiting rows as `opted_out`.

### Sending a founding update

1. Write the update as markdown in the repo, first line `# Subject`, then the body: paragraphs separated by blank
   lines, lists as `- ` lines. No HTML; links stay as text and mail apps make them links. Merge it to main.
2. Actions → Founding update → Run workflow, from main: target `production` (or `staging` to try it), mode
   `preview`, file `docs/updates/<name>.md`. The preview arrives at `FOUNDING_UPDATES_PREVIEW_TO` with "[Preview]" in
   the subject, and the run's log says how many adults would get it (`audience`).
3. Read the preview. Then run it again with mode `send` and confirm `send`. The log shows `queued`; the cron sends at
   most 200 an hour (shared with every other account email), so a large list takes a few hours. A row not sent within
   2 days is dropped as `stale`, so above about 9,000 opted-in adults this needs a bigger cap first.

```sql
-- Opt-ins (counts only):
select count(*) filter (where weekly_plan) as weekly_plan, count(*) filter (where founding_updates) as founding
  from public.email_preferences;
-- How an update is going:
select last_error_code, count(*) filter (where sent_at is not null) as sent, count(*) as total
  from public.email_outbox where kind = 'founding_update' and created_at > now() - interval '3 days' group by 1;
```

## Monitoring (SQL editor, read only)

```sql
-- The Vault secrets are there (names only, never values):
select name, length(decrypted_secret) > 0 as has_value
  from vault.decrypted_secrets
 where name in ('account_email_function_url', 'account_email_cron_secret');

-- The flag:
select account_email_enabled from public.app_config;

-- The outbox in the last day, by kind and outcome:
select kind,
       count(*) filter (where sent_at is not null) as sent,
       count(*) filter (where failed_at is not null) as dropped,
       count(*) filter (where sent_at is null and failed_at is null) as waiting
  from public.email_outbox
 where created_at > now() - interval '1 day'
 group by kind;

-- Why rows were dropped or are retrying:
select last_error_code, count(*) from public.email_outbox
 where last_error_code is not null and created_at > now() - interval '7 days'
 group by 1 order by 2 desc;

-- The cron ran, and pg_net got an answer (200 with {sent, failed, unwritable}; 401 means the two secrets differ;
-- 503 email_off means ACCOUNT_EMAIL_FROM or RESEND_API_KEY is missing):
select status, return_message, start_time from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'kick-account-email')
 order by start_time desc limit 5;
select status_code, content, created from net._http_response order by created desc limit 5;
```

Many `no_address` rows mean accounts without an Apple email (or `email_verified: false`); many `not_adult` rows are
expected only for households that changed owner or removed someone. A run answering 200 with `sent: 0` while rows wait
can be the hourly cap.

## Check it works (staging, then production)

1. With the flag on, create a household from a staging build with a Hide My Email account. Within 5 minutes the
   welcome arrives at the real inbox from `info@getfoon.com`.
2. Load a sample family instead: no welcome. Start your real family: the welcome arrives.
3. Buy the sandbox subscription: "Your Foon free trial has started" arrives with the trial's end date. Turn off
   renewal in Settings: "Your Foon subscription won't renew"; turn it back on: "Your Foon subscription will renew".
   Sandbox renewals are fast, so "Your Foon subscription renewed" follows within minutes; switching plan in
   Subscriptions gives "Your Foon plan is changing" (or "has changed" for an upgrade). A failed payment, a refund
   and a grace period ending have their own; they're easiest to trigger from Xcode's StoreKit transaction manager.
4. Delete household, then Delete my account: one receipt each, to the person who did it.
5. Edge Functions → account-email and delete-account → Logs: ids and codes only, never an address.
6. Family → Email: turn on the weekly plan email (the wording shows first). Approve a week: about 10 minutes later the
   email lists its dinners. Un-approve and approve it again: nothing more arrives. Then turn it off from the email and
   check Family → Email shows it off after a refresh. On staging, use the mail app's own Unsubscribe button (one-click
   POSTs straight to staging's function): the Unsubscribe link in the footer opens getfoon.com, whose button POSTs to
   production's function, which rejects staging's signature ("This link didn't work"). The footer link works on
   staging only if `ACCOUNT_EMAIL_SITE_URL` points at a site built with `NUXT_PUBLIC_WAITLIST_URL` set to staging. On
   production, both the footer link (the site page's button) and the mail app's button work.
7. Turn on founding-family updates, then run the Founding update Action on staging in preview mode, then send: the
   email has the postal address, why you got it, and an unsubscribe link; the mail app's own Unsubscribe works too.
8. Sign in as a kid: Family has no Email section.
9. Emailed invite (#48 PR B): as a parent, Family → an unclaimed adult → Invite → Email the invite, type a real inbox,
   Send. "<you> invited you to <household> on Foon" arrives with the www.getfoon.com/invite link and the code. Then
   `select * from invite_email_sends` shows one row with no address, and the function's logs show none either. A
   kid's profile has no Email the invite. With the sheet open on one device, invite the same person again from
   another parent's device: Send on the first then says the code was replaced. With the flag off, the sheet says "Foon doesn't send email yet."

## Emailed invites (PR B)

Database side: `supabase/migrations/20261128000000_invite_email.sql`. The app POSTs `{memberId, code, email}` to
`account-email?invite=1` with the parent's JWT (`invite.ts`). `reserve_invite_email`, run as the parent, checks they're
a parent in the household, the profile is an unclaimed adult's, the flag is on, the code is that profile's open invite,
and the limits (5 a day per parent, 10 a day per household, 200 an hour overall), then records the send in
`invite_email_sends` (household, sender, time; pruned daily after a day) and returns what the email says. The address
goes only to Resend: no table, log line or response carries it. A failed send still counts toward the limits.
