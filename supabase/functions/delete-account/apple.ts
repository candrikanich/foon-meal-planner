// Sign in with Apple token revocation, which App Review requires when an account is deleted.
// The app sends a fresh authorization code (the person confirms with Apple). We trade it for a refresh token,
// then revoke that, which ends Foon's link to their Apple ID. The private key stays in Edge Function secrets.

import { signES256 } from "../_shared/es256.ts";

export interface AppleConfig {
  teamId: string;
  keyId: string;
  // The app's bundle id: native Sign in with Apple uses it as the client id.
  clientId: string;
  // The .p8 key's contents (PKCS #8 PEM).
  privateKey: string;
}

const appleAuth = "https://appleid.apple.com";

export function appleConfigFromEnv(get: (key: string) => string | undefined): AppleConfig | null {
  const teamId = get("APPLE_TEAM_ID");
  const keyId = get("APPLE_KEY_ID");
  const clientId = get("APPLE_CLIENT_ID");
  const privateKey = get("APPLE_PRIVATE_KEY");
  if (!teamId || !keyId || !clientId || !privateKey) return null;
  return { teamId, keyId, clientId, privateKey };
}

// The short-lived ES256 JWT Apple takes as a client secret.
export function clientSecret(config: AppleConfig, now: Date = new Date()): Promise<string> {
  const issuedAt = Math.floor(now.getTime() / 1000);
  return signES256(
    { kid: config.keyId },
    { iss: config.teamId, iat: issuedAt, exp: issuedAt + 300, aud: appleAuth, sub: config.clientId },
    config.privateKey,
  );
}

// The code came from a different Apple ID than the one the account signed up with (a shared Mac, say). Revoking it
// wouldn't end the account's own link, so nothing is done.
export class AppleAccountMismatch extends Error {}

// The `sub` claim of Apple's id_token. It comes straight from Apple over TLS, so there's no signature to check here.
export function idTokenSubject(idToken: string | undefined): string | null {
  const payload = idToken?.split(".")[1];
  if (!payload) return null;
  try {
    const json = atob(payload.replaceAll("-", "+").replaceAll("_", "/"));
    const sub = (JSON.parse(json) as { sub?: unknown }).sub;
    return typeof sub === "string" ? sub : null;
  } catch {
    return null;
  }
}

// Trades the authorization code for a token and, when it belongs to `appleSubject`, revokes it. Throws when Apple
// refuses either step, and AppleAccountMismatch (before revoking) when the code is another Apple ID's.
export async function revokeAppleToken(
  authorizationCode: string,
  appleSubject: string,
  config: AppleConfig,
  fetchFn: typeof fetch = fetch,
): Promise<void> {
  const secret = await clientSecret(config);
  const exchange = await fetchFn(`${appleAuth}/auth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: config.clientId,
      client_secret: secret,
      code: authorizationCode,
      grant_type: "authorization_code",
    }),
  });
  if (!exchange.ok) throw new Error(`apple token exchange failed: ${exchange.status}`);
  const tokens = await exchange.json() as { refresh_token?: string; access_token?: string; id_token?: string };
  if (idTokenSubject(tokens.id_token) !== appleSubject) throw new AppleAccountMismatch();
  const [token, hint] = tokens.refresh_token
    ? [tokens.refresh_token, "refresh_token"]
    : [tokens.access_token, "access_token"];
  if (!token) throw new Error("apple token exchange returned no token");

  const revoke = await fetchFn(`${appleAuth}/auth/revoke`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: config.clientId,
      client_secret: secret,
      token,
      token_type_hint: hint,
    }),
  });
  if (!revoke.ok) throw new Error(`apple revoke failed: ${revoke.status}`);
}
