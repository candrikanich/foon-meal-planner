# Parental consent email: setup and checks (#275)

How consent by "email plus" behaves is in [spec.md](spec.md) (Email → Consent email to parents) and the legal side in
[legal/privacy.md](legal/privacy.md). This is what to configure and what to verify. The function is
`supabase/functions/parental-consent`, the database side `supabase/migrations/20261116000000_email_plus_consent.sql`.

## Configure

| Where | Name | Notes |
| --- | --- | --- |
| Edge Function secret | `RESEND_API_KEY` | Already set for the waitlist; the same key sends both |
| Edge Function secret | `CONSENT_FROM` | `Foon <info@getfoon.com>` (decided 2026-11-08). Must be on a domain verified in Resend. Without it (or the key) nothing is sent and the app is told email is off (503 `email_off`). A first request that never sent anything is deleted; a Send again leaves the existing request and its live link as they were |
| Edge Function secret | `CONSENT_SITE_URL` | Optional. Defaults to `https://getfoon.com`; set it to point the emailed links at a preview. Its origin is then also allowed to POST (CORS), so the preview's pages work |
| Vercel env (build time) | `NUXT_PUBLIC_CONSENT_URL` | `https://<project-ref>.supabase.co/functions/v1/parental-consent`, which the site's /consent pages POST to. Required in every environment the site builds in (Production and Preview): `nuxt build` fails without it, and a new value takes effect only after a redeploy |
| Edge Function (built in) | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Set by Supabase. The anon key is used only to run the parent's request as the parent (their JWT) |
| Edge Function secret | `CONSENT_CRON_SECRET` | Renewal emails (#277). A long random string, the same value as Vault's `consent_cron_secret`. Unset, `?renewals=1` answers 401 and no renewal email goes |
| Vault (database) | `consent_function_url` | `https://<project-ref>.supabase.co/functions/v1/parental-consent`. `kick_consent_renewals()` POSTs to it with `?renewals=1` |
| Vault (database) | `consent_cron_secret` | Same value as `CONSENT_CRON_SECRET`; sent in the `x-consent-cron-secret` header. Without both Vault secrets the cron does nothing, silently |

Set the secrets on staging and production (Supabase → Edge Functions → Secrets, or
`supabase secrets set CONSENT_FROM='Foon <info@getfoon.com>' --project-ref <ref>`). Deploys need nothing new: both
deploy workflows deploy every function, and `config.toml` turns the gateway's JWT check off for this one (the links
carry none; the function checks the app's JWT itself).

Vault secrets (SQL editor, once per project; never commit the values):

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/parental-consent', 'consent_function_url');
select vault.create_secret('<the same value as CONSENT_CRON_SECRET>', 'consent_cron_secret');
```

## Renewal emails (#277)

When a parental wording newer than the one a parent agreed to comes into force (`agreement_versions`), the kid is held:
signed out, profile kept, nothing erased. Every 15 minutes `kick-consent-renewals` (pg_cron) calls
`kick_consent_renewals()`, which POSTs `?renewals=1` with `x-consent-cron-secret` only when some hold owes an email.
The function checks the secret (constant-time), claims up to 50 emails (`claim_consent_renewal_emails`), and for each
sends the renewal notice, then records it with `parental_consent_mark_sent` and its own `TEXT_VERSION`; a send that
fails is released (`parental_consent_release_send`) and tried on a later run.

- **Renewal notice** ("Can <name> keep using Foon?"), to every parent whose account has a verified email: email 1's
  direct notice, plus what changed (the registry's `summary`), when a parent agreed before, that the kid is signed out
  until a parent agrees, that nothing is deleted, and how to withdraw instead. Its link opens the same /consent page,
  worded as a renewal; No keeps the kid signed out.
- **Reminder**, once, 7 days after the first: the same email, subject "Reminder: Can <name> keep using Foon?".
- A parent's Email me the form in the app sends the same notice, without what changed and the date (the app's request
  doesn't return them).
- If a hold asks for wording other than the function's `TEXT_VERSION`, nothing is sent: the claim is released and the
  run answers 503 `wording_outdated` (the app's request answers the same). Deploy the function with the new wording
  before the registry row comes into force (legal/README.md, Wording versions).

Check: Edge Functions → parental-consent → Logs shows a run every 15 minutes while holds owe emails, answering 200
with `{sent, failed, outdated, unrecorded}`. A 401 means the two secrets differ.

## Which address is used

The email Apple gave for the account's Sign in with Apple identity: `auth.identities.identity_data ->> 'email'` where
`provider = 'apple'`, and not marked `email_verified: false`. Not `auth.users.email`, which a signed-in user can change
through Auth while the Apple identity stays; and `email_confirmed_at` proves nothing while sign-ups autoconfirm. With no
such identity email, the app is told `no_email` and the parent types one. A typed address is the parent's own claim;
the notice sent there is what confirms it. Email 2 goes only to the address email 1 went to: the request keeps its
SHA-256 and compares it before sending; a mismatch cancels the request. The local `config.toml` has email sign-ups on
with confirmations off (`[auth.email]`, the CLI default); check the hosted projects' Auth settings, though only the
Apple identity's email is used either way.

## Sign in with Apple's private email relay (Chris)

Parents who chose Hide My Email have a `@privaterelay.appleid.com` address. Apple forwards mail to it only from
registered senders; anything else bounces.

1. Apple Developer → Certificates, Identifiers & Profiles → Services → Sign in with Apple for Email Communication →
   Configure.
2. Register the domain `getfoon.com` and the address `info@getfoon.com`.
3. [CHECK] whether Resend's return-path (bounce) domain, `send.getfoon.com`, needs registering too. Apple checks SPF on
   the envelope sender, which Resend sets to its own subdomain.
4. Apple requires SPF to pass and DKIM to sign for the registered domain. Both come from verifying `getfoon.com` in
   Resend (its DNS records); confirm Resend → Domains shows it verified.

## Check it works (staging, then production)

1. From a staging build, sign in with a Hide My Email account, add a kid's profile and request consent. Email 1 should
   arrive at the real inbox, from `info@getfoon.com`, and its link should open getfoon.com/consent (or the preview).
2. Tap I agree: email 2 arrives, and the kid's profile now shows Invite. Tap Withdraw consent in email 2: the kid's
   profile asks for consent again.
3. Supabase → Edge Functions → parental-consent → Logs: lines name request ids and outcomes only, never an address,
   a name or a token.
4. Repeat once with an account whose email is a normal address, and once with No on the site page.

## Before production

Consents given in the app before #275 aren't verifiable consent; they're tagged `method = 'in_app'` and stay active
until #277 holds them (decided 2026-11-08). Count them on production before launch (read only):

```sql
select count(*) from public.consents where kind = 'parental' and revoked_at is null and method = 'in_app';
```

Pre-launch this should be 0, or only our own family.

## What the emailed links do

Mail scanners open every link in a message, so a GET never changes anything:

- `GET …/parental-consent?consent=<token>` redirects (303) to `/consent?t=<token>` on the site; that page's buttons
  POST the parent's answer.
- `GET …/parental-consent?withdraw=<token>` redirects to `/consent/withdraw?t=<token>`, whose button POSTs.
- A token that doesn't look like one goes to `/consent/expired` (`?link=withdraw` for the withdraw link).

The database stores only SHA-256 hashes of both tokens. The consent link works for 7 days and Send again replaces it;
the withdraw link works for 30 days, and withdrawing in the app always works. The site's POST must come from
getfoon.com, www.getfoon.com, localhost, or the origin of `CONSENT_SITE_URL` (CORS).

## Known limit

The server checks everything when the parent taps I agree, sends email 2, then checks again before activating. If
something changes in those seconds (the kid's profile is claimed or removed, the parent stops being a parent, or
another parent's consent lands first), email 2 has already gone out but no consent from this request is activated:
the page shows the real outcome (`expired` or `already_consented`), and email 2's withdraw link leads to the
expired page. Ordering can't close this: the rule makes the confirming email the step that activates consent.

## Limits

One email 1 per request every 10 minutes, 5 a day per parent, 10 a day per household, 200 an hour overall,
reserved under a lock in `request_parental_consent`. The overall cap is a cost and abuse ceiling, as for the
waitlist. The tradeoff we accept: someone with many accounts and households could use it up and delay other
parents' emails by up to an hour (each account is held to 5 a day and each household to 10). Sends record their household and parent
themselves, so deleting a request or the kid doesn't reset a count; they go after a day, or with the household. The app is told
`rate_limited` and says "Try again in a little while." A send that fails is released and stops counting. A reservation nobody settled (say, the RPC called
directly and no email sent) keeps counting toward the per-parent, per-household and overall limits for their whole
window; only the per-request "sending now" check lapses after 5 minutes.
Email 2 is reserved per request for 5 minutes, so two taps of I agree send it once.

## Retention

A daily job (`purge-parental-consent-requests`, 04:23 UTC) ends requests whose link lapsed, drops a request whose
email never went out, and deletes a request 30 days after it ended (which also ends its withdraw link). Send
bookkeeping goes after a day. Resend keeps its own logs of each send (see docs/legal/retention.md).
