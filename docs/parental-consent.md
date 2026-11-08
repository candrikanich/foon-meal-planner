# Parental consent email: setup and checks (#275)

How consent by "email plus" behaves is in [spec.md](spec.md) (Email → Consent email to parents) and the legal side in
[legal/privacy.md](legal/privacy.md). This is what to configure and what to verify. The function is
`supabase/functions/parental-consent`, the database side `supabase/migrations/20261116000000_email_plus_consent.sql`.

## Configure

| Where | Name | Notes |
| --- | --- | --- |
| Edge Function secret | `RESEND_API_KEY` | Already set for the waitlist; the same key sends both |
| Edge Function secret | `CONSENT_FROM` | `Foon <info@getfoon.com>` (decided 2026-11-08). Must be on a domain verified in Resend. Without it (or the key) nothing is sent: the app is told email is off (503 `email_off`) and no request is kept |
| Edge Function secret | `CONSENT_SITE_URL` | Optional. Defaults to `https://getfoon.com`; set it to point the emailed links at a preview |
| Edge Function (built in) | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Set by Supabase. The anon key is used only to run the parent's request as the parent (their JWT) |

Set the secrets on staging and production (Supabase → Edge Functions → Secrets, or
`supabase secrets set CONSENT_FROM='Foon <info@getfoon.com>' --project-ref <ref>`). Deploys need nothing new: both
deploy workflows deploy every function, and `config.toml` turns the gateway's JWT check off for this one (the links
carry none; the function checks the app's JWT itself).

## Which address is used

The account's email, only when it's verified: `auth.users.email_confirmed_at` is set, or the account has an Apple
identity. Otherwise the app is told `no_email` and the parent types one. Email 2 goes only to the address email 1
went to: the request keeps its SHA-256 and compares it before sending; a mismatch cancels the request. The local
`config.toml` has email sign-ups on with confirmations off (`[auth.email]`, the CLI default); check the hosted
projects' Auth settings, though an unconfirmed email is never used either way.

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
getfoon.com, www.getfoon.com or localhost (CORS).

## Limits

One email 1 per request every 10 minutes, 5 a day per parent, 10 a day per household, 200 an hour overall,
reserved under a lock in `request_parental_consent`. The overall cap is a cost and abuse ceiling, as for the
waitlist. The tradeoff we accept: someone with many accounts and households could use it up and delay other
parents' emails by up to an hour (each account is held to 5 a day and each household to 10). The app is told
`rate_limited` and says "Try again in a little while." A send that fails is released; a reservation nobody settled lapses after 5 minutes.
Email 2 is reserved per request for 5 minutes, so two taps of I agree send it once.

## Retention

A daily job (`purge-parental-consent-requests`, 04:23 UTC) ends requests whose link lapsed, drops a request whose
email never went out, and deletes a request 30 days after it ended (which also ends its withdraw link). Send
bookkeeping goes after a day. Resend keeps its own logs of each send (see docs/legal/retention.md).
