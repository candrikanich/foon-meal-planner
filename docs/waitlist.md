# Waitlist: setup and checks (#34)

How the waitlist behaves is in [spec.md](spec.md) (Marketing presence). This is what to configure and what to verify.

## Configure

| Where | Name | Notes |
| --- | --- | --- |
| Edge Function secret | `RESEND_API_KEY`, `WAITLIST_FROM` | Both needed to send. Without them signups are stored and the log says email is off. `WAITLIST_FROM` is like `Foon <hello@getfoon.com>`, on a domain verified in Resend |
| Edge Function secret | `WAITLIST_SITE_URL` | Optional. Defaults to `https://getfoon.com`; set it to point the emailed links at a preview |
| Vercel env (build time) | `NUXT_PUBLIC_WAITLIST_URL` | `https://<project-ref>.supabase.co/functions/v1/waitlist` |

## What the emailed links do

Mail scanners (Safe Links, Mimecast and the like) open every link in a message, so a GET never changes anything. The
function's `GET ?confirm=` and `GET ?unsubscribe=` only redirect to the site's `/waitlist/confirm` and
`/waitlist/unsubscribe` pages, which have a button that POSTs to the function. The mail client's one-click unsubscribe
(`List-Unsubscribe-Post`, RFC 8058) POSTs straight to the function.

## Client address: what is and isn't guaranteed

The 5-an-hour limit is per client address, kept as a keyed hash (IPv6 by its /64). Supabase doesn't document which
client-address headers a hosted Edge Function can trust (nothing in its docs; GitHub discussions #7884 and #34647 leave
it open, and report a client-sent `x-forwarded-for` getting through). So the function prefers `cf-connecting-ip`, falls
back to the last `x-forwarded-for` entry, and ignores `x-real-ip`. If those turn out to be spoofable, the only loss is
the per-address limit: the 200-emails-an-hour cap counts reserved and sent emails and doesn't depend on the address.

## Verify the address headers on staging (after the function is deployed)

No debug code is needed. Send six signups from one machine, each with a different forged forwarding header, and see
whether they are still treated as one address:

```sh
URL="https://<staging-ref>.supabase.co/functions/v1/waitlist"
for n in 1 2 3 4 5 6; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$URL" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: 10.0.0.$n" -H "CF-Connecting-IP: 10.1.0.$n" \
    -d "{\"email\":\"check$n@example.com\"}"
done
```

- Expect 200 five times, then **429**. That means the forged headers were ignored or overwritten.
- In the SQL editor, `select ip_hash, count(*) from public.waitlist_attempts group by 1;` should show one hash with 6.
- If you instead get six 200s and six different hashes, the headers are spoofable on this platform: say so, and the
  per-address limit is only a speed bump (the overall cap still holds).
- Clean up: `delete from public.waitlist_signups where email like 'check%@example.com';`
- Repeat once without the forged headers from a second network (a phone hotspot): its attempts must have a different hash.
