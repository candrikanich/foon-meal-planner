import { hex } from "../_shared/token.ts";

// HMAC-SHA256 keyed by a secret the function already has, so unsubscribe links need no stored token.
export function signer(secret: string): (id: string) => Promise<string> {
  const key = crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`waitlist-unsubscribe:${secret}`),
    {
      name: "HMAC",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );
  return async (id) =>
    hex(
      await crypto.subtle.sign("HMAC", await key, new TextEncoder().encode(id)),
    ).slice(0, 32);
}
