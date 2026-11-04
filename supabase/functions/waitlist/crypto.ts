const hex = (bytes: ArrayBuffer) => Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");

export async function sha256(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

// 32 random bytes as base64url: what the confirmation link carries. Only its sha256 is stored.
export function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// HMAC-SHA256 keyed by a secret the function already has, so unsubscribe links need no stored token.
export function signer(secret: string): (id: string) => Promise<string> {
  const key = crypto.subtle.importKey("raw", new TextEncoder().encode(`waitlist-unsubscribe:${secret}`), {
    name: "HMAC",
    hash: "SHA-256",
  }, false, ["sign"]);
  return async (id) => hex(await crypto.subtle.sign("HMAC", await key, new TextEncoder().encode(id))).slice(0, 32);
}
