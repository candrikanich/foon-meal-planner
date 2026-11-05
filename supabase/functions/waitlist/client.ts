// Which address a request came from, for the per-address rate limit.
//
// What hosted Supabase Edge Functions guarantee about client-address headers is NOT documented (checked: Supabase docs,
// and GitHub discussions #7884 and #34647, where a client-supplied x-forwarded-for is reported to reach functions and
// the question of what is safe is unanswered). So nothing here is treated as a guarantee:
// * cf-connecting-ip is preferred: Cloudflare sets it and replaces any value the client sent, and Supabase's edge sits
//   behind Cloudflare, but Supabase doesn't say that headers reach functions untouched.
// * otherwise the LAST x-forwarded-for entry, which is added by the proxy nearest us; the first is whatever the caller wrote.
// * x-real-ip is not used: nothing says who sets it.
// docs/waitlist.md records the production check and how to re-run it. Whatever this returns, the database's cap
// of 200 emails an hour holds, so a spoofer can bypass the 5-an-hour limit at worst, never the overall one.
export function callerAddress(headers: Headers): string {
  const cloudflare = headers.get("cf-connecting-ip")?.trim();
  if (cloudflare) return cloudflare;
  const hops =
    headers.get("x-forwarded-for")?.split(",").map((hop) => hop.trim()).filter(
      Boolean,
    ) ?? [];
  return hops.at(-1) ?? "unknown";
}

// IPv6 addresses are limited by their /64: one household or host holds a whole /64, and can pick any address inside it.
export function networkOf(address: string): string {
  const mapped = address.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i);
  if (mapped) return mapped[1];
  if (!address.includes(":")) return address;
  const [head, tail = ""] = address.toLowerCase().split("::");
  const front = head.split(":").filter(Boolean);
  const back = tail.split(":").filter(Boolean);
  const hextets = address.includes("::")
    ? [
      ...front,
      ...Array(Math.max(0, 8 - front.length - back.length)).fill("0"),
      ...back,
    ]
    : front;
  return hextets.slice(0, 4).map((hextet) => hextet.replace(/^0+(?=.)/, ""))
    .join(":") + "::/64";
}

export const clientKey = (headers: Headers): string =>
  networkOf(callerAddress(headers));

// Constant-time, so a wrong signature can't be corrected one character at a time by timing.
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}
