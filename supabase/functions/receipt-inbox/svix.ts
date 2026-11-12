// Resend signs its webhooks the Svix way. Checked here with WebCrypto rather than the svix package, which would pull a
// dependency in for one HMAC.
import { sameSecret } from "../_shared/token.ts";

// Svix's own tolerance: an older (or future) delivery is a replay, not Resend.
export const SVIX_TOLERANCE_SECONDS = 5 * 60;

export interface SvixHeaders {
  id: string | null;
  timestamp: string | null;
  signature: string | null;
}

export const svixHeaders = (headers: Headers): SvixHeaders => ({
  id: headers.get("svix-id"),
  timestamp: headers.get("svix-timestamp"),
  signature: headers.get("svix-signature"),
});

function base64ToBytes(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

const bytesToBase64 = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes)));

// The base64 signature Svix would put after "v1," for this delivery.
export async function svixSignature(secret: string, id: string, timestamp: string, body: string): Promise<string> {
  const keyBytes = base64ToBytes(secret.replace(/^whsec_/, ""));
  if (!keyBytes) throw new Error("webhook secret isn't base64");
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`));
  return bytesToBase64(signed);
}

// True when one of the header's "v1,<sig>" entries is this body's, signed in the last five minutes. The header holds
// several during a secret rotation, so any match passes.
export async function verifySvix(
  secret: string,
  headers: SvixHeaders,
  body: string,
  nowMs: number,
): Promise<boolean> {
  const { id, timestamp, signature } = headers;
  if (!id || !timestamp || !signature || !/^\d{1,12}$/.test(timestamp)) return false;
  if (Math.abs(nowMs / 1000 - Number(timestamp)) > SVIX_TOLERANCE_SECONDS) return false;
  let expected: string;
  try {
    expected = await svixSignature(secret, id, timestamp, body);
  } catch {
    return false;
  }
  return signature.split(" ").some((entry) => {
    const [version, value] = entry.split(",", 2);
    return version === "v1" && value !== undefined && sameSecret(value, expected);
  });
}
