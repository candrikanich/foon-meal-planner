// Tokens for emailed links. A link carries the token; only its sha256 is stored.
export const hex = (bytes: ArrayBuffer) =>
  Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0"))
    .join("");

export async function sha256(value: string): Promise<string> {
  return hex(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
}

// 32 random bytes as base64url.
export function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(
    /\//g,
    "_",
  ).replace(/=+$/, "");
}

// What a token in a link looks like; anything else is refused before it reaches the database.
export const tokenPattern = /^[A-Za-z0-9_-]{20,100}$/;
