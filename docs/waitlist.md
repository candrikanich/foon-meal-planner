# Waitlist: setup and checks (#34)

How the waitlist behaves is in [spec.md](spec.md) (Marketing presence). This is what to configure and what to verify.

## Configure

| Where | Name | Notes |
| --- | --- | --- |
| Edge Function secret | `RESEND_API_KEY`, `WAITLIST_FROM` | Both needed to send. Without them signups are stored and the log says email is off. `WAITLIST_FROM` is like `Foon <hello@getfoon.com>`, on a domain verified in Resend |
| Edge Function secret | `WAITLIST_SITE_URL` | Optional. Defaults to `https://getfoon.com`; set it to point the emailed links at a preview |
| Vercel env (build time) | `NUXT_PUBLIC_WAITLIST_URL` | `https://<project-ref>.supabase.co/functions/v1/waitlist`. Required in every environment the site builds in: `nuxt build` fails without it |

## Production

The live site uses Foon production (`itnhdikhdsujklaimqqd`), not staging. Merges to main only reach staging; production
is updated by hand with **Deploy production** (`.github/workflows/deploy-production.yml`): Actions → Deploy production
→ Run workflow on `main`, type `production`, then approve the `production` environment. It refuses any other branch,
any other text, and any project but `itnhdikhdsujklaimqqd`, then runs the same steps as staging (migrations, starter
catalog, all Edge Functions).

One-time setup, done by Chris (values never go in the repo or a chat):

1. GitHub → Settings → Environments → `production`, with Chris as required reviewer, deployment branches limited to
   `main` (a run from another branch, whose copy of the workflow could drop the checks, never gets the secrets), and
   these secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD` (production's), `SUPABASE_PROJECT_REF`
   (`itnhdikhdsujklaimqqd`).
2. Production Edge Function secrets `RESEND_API_KEY` and `WAITLIST_FROM`, before the first run so the waitlist can
   send as soon as it's deployed.
3. After the first run, Vercel production gets
   `NUXT_PUBLIC_WAITLIST_URL=https://itnhdikhdsujklaimqqd.supabase.co/functions/v1/waitlist`, then a redeploy.

Push (Apple key, vault secrets) and App Store notification secrets aren't needed for the waitlist; they're set when the
app itself moves to production. Until then those functions are deployed but idle.

## What the emailed links do

Mail scanners (Safe Links, Mimecast and the like) open every link in a message, so a GET never changes anything. The
function's `GET ?confirm=` and `GET ?unsubscribe=` only redirect to the site's `/waitlist/confirm` and
`/waitlist/unsubscribe` pages, which have a button that POSTs to the function. The mail client's one-click unsubscribe
(`List-Unsubscribe-Post`, RFC 8058) POSTs straight to the function.

**Checked on production, 2026-11-09,** with a real iCloud address on getfoon.com:

- Signup showed "Almost done", and the confirmation email arrived.
- The email's Confirm my email link opened Confirm your email, and its button led to "You're on the list".
- The email's Unsubscribe link opened Unsubscribe, and Delete my address led to "You're unsubscribed".
- The email had no postal address: production's functions were last deployed 2026-11-05, before #284 added it, so the
  footer arrives with the next production deploy.

## Client address: what is and isn't guaranteed

The 5-an-hour limit is per client address, kept as a keyed hash (IPv6 by its /64). Supabase doesn't document which
client-address headers a hosted Edge Function can trust (nothing in its docs; GitHub discussions #7884 and #34647 leave
it open, and report a client-sent `x-forwarded-for` getting through). So the function prefers `cf-connecting-ip`, falls
back to the last `x-forwarded-for` entry, and ignores `x-real-ip`. If those turn out to be spoofable, the only loss is
the per-address limit: the 200-emails-an-hour cap counts reserved and sent emails and doesn't depend on the address.

**Checked on production, 2026-11-05:**

- A request carrying its own `CF-Connecting-IP` never reaches the function: Cloudflare answers 403 (error 1000).
- With forged `X-Forwarded-For` and `X-Real-IP` values, different on every request, one machine got 200 five times,
  then 429. The forged values were ignored and all six counted as one address.
- A signup from a phone on cellular got its own hash in `waitlist_attempts`, apart from the first network's: two
  networks were counted separately. (That doesn't rule out visitors behind one shared proxy hop sharing a key.)

## Re-run the address check (after a platform or function change)

No debug code is needed. Send seven signups from one machine, each with a different forged forwarding header. All of
them use the same address on Resend's test inbox: it accepts mail without bouncing, and a repeat within 10 minutes
sends nothing, so the check sends one email in all. Don't use `example.com` addresses: each would send a real email
that bounces and hurts the sending domain.

```sh
URL="https://<project-ref>.supabase.co/functions/v1/waitlist"
for n in 1 2 3 4 5 6 7; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$URL" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: 10.0.0.$n" -H "X-Real-IP: 10.2.0.$n" \
    -d '{"email":"delivered+foon-header-check@resend.dev"}'
done
```

- Expect 200 five times, then 429 twice. That means the forged headers were ignored. (Fewer 200s means this network
  already made attempts in the last hour; it's the same result.)
- If you instead get seven 200s, the headers are spoofable on this platform: say so, and the per-address limit is
  only a speed bump (the overall cap still holds).
- Then, while this network is at its limit, send the same request once more with `-H "CF-Connecting-IP: 10.1.0.9"`
  added. Expect 403 from Cloudflare. A 429 is also fine: the header was replaced with the real address. A 200 means
  `client.ts` trusted the forged value: fix it before anything else.
- Within the hour, sign up on the site from a phone on cellular (Wi-Fi off) with the same
  `delivered+foon-header-check@resend.dev` address (no second email goes out, and the cleanup below covers it). It
  must succeed; "slow down" means both networks share one key. Then, in the SQL editor:

  ```sql
  select ip_hash, count(*), max(attempted_at) from public.waitlist_attempts
  where attempted_at > now() - interval '15 minutes' group by 1 order by 3 desc;
  ```

  The newest row (the phone) must have a different hash from the one with the curl run's attempts. If it's the same,
  fix `client.ts` before anything else. Other hashes in the table are other visitors and don't count either way.
- Everyone on this network (same public address, or same IPv6 /64) can't sign up for about an hour, and each retry
  extends that, because refused attempts count too.
- Clean up in the SQL editor: `delete from public.waitlist_signups where email = 'delivered+foon-header-check@resend.dev';`
  (left alone, it's deleted after 30 days).
