# Subscriptions

How the server side of Foon's subscriptions (#66) is set up and tested. The rules are in [spec.md](spec.md) → Payments.

## Notification URL

In App Store Connect → the app → App Information → App Store Server Notifications, set both the production and the
sandbox URL, with **Version 2**:

```
https://<project-ref>.supabase.co/functions/v1/app-store-notifications
```

Staging is `cbftcssbnfdjjxoeflvj`. Apple takes one production and one sandbox URL. TestFlight and App Review buy in the
sandbox, so the sandbox URL has to point at the project those builds talk to: staging during the beta, production once
App Review tests a build that talks to production (staging's TestFlight purchases then stop reaching staging; decide
before launch). Sandbox subscriptions are accepted on purpose, since App Review's purchase has to unlock the app; each
event records its environment.

The function is deployed with the others on a merge to main (deploy-staging.yml). It skips Supabase's JWT check
(`config.toml`), since Apple sends none; the signature on the payload is the check.

## Secrets and settings

- **Verification needs no secret.** Apple Root CA - G3 ships with the function (`apple_root_ca_g3.ts`, pinned by its
  SHA-256 fingerprint in a test). Production checks are online: certificate dates against now, and OCSP revocation.
- **`APPLE_APP_ID`** (Edge Function secret, though it's public): the app's numeric Apple ID from App Store Connect → App
  Information. Apple's library needs it to check production notifications. Until it's set, sandbox notifications work and
  production ones get a 500, so Apple retries them (for about 3 days) once it is.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided by Supabase.

## Turning billing on

`app_config.billing_enforced` is off: every household is entitled during the beta. At launch, a migration sets it on
(never by hand in the dashboard, so staging and production can't drift):

```sql
update public.app_config set billing_enforced = true;
```

## Testing with the sandbox

1. In Xcode, Run uses `Foon/Foon.storekit` (no Apple servers, no notifications). To reach the server, run without it:
   Edit Scheme → Run → Options → StoreKit Configuration → None, or use a TestFlight build.
2. Make a sandbox tester in App Store Connect → Users and Access → Sandbox, and sign in with it on the device (Settings
   → Developer → Sandbox Apple Account). Sandbox renewals are fast: a month renews every 5 minutes, up to 12 times.
3. Buy. The app has to pass the household's id as `appAccountToken` (the client half); without it the notification is
   ignored.
4. Watch the function's logs in the Supabase dashboard (types, outcomes and notification ids only), and check:

```sql
select notification_type, subtype, outcome, signed_at from public.subscription_events
where household_id = '<household id>' order by signed_at;

select original_transaction_id, status, expires_at from public.household_subscriptions
where household_id = '<household id>';

select subscription_status, subscription_expires_at, public.household_entitled(id)
from public.households where id = '<household id>';
```

5. To check the URL and signature without a purchase, ask Apple for a TEST notification
   (`POST /inApps/v1/notifications/test` on the App Store Server API, which needs an In-App Purchase key). The function
   answers it with `{"result":"test"}` and stores nothing.

Function responses: 200 for handled (`applied`, `stale`, `duplicate`) and ignored (with a reason);
400 when the payload isn't Apple's (signature, chain, bundle id, environment); 500 when we couldn't apply it.

## Ownership transfer

The entitlement stays with the household. The old owner's subscription carries the household's id, so it keeps the
household unlocked until it lapses; they cancel it in their Apple account settings. The new owner can subscribe too. Each
Apple subscription has its own row in `household_subscriptions`, and the household is entitled while any of them grants
access, so the old one lapsing can't lock out the new one.
