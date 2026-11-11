// Unsubscribing from an opt-in email (#48, PR C), through account-email:
//   GET  ?unsubscribe=<kind>.<user id>.<signature>   no side effects: a redirect to getfoon.com/email/unsubscribe, because
//                                                    link scanners open every link in an email before the person does
//   POST ?unsubscribe=…                              turns that email off: from the site page's button, or a mail app's
//                                                    one-click (RFC 8058, no Origin)
// The signature is an HMAC of the email and the person, so a link needs nothing stored and works only for its own email.
import { unsubscribeSigner } from "../_shared/email_layout.ts";
import { sameSecret } from "../_shared/token.ts";
import { OPT_IN_KINDS, type OptInKind } from "./opt_in_email.ts";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Signs with a secret the function already has (the service role key, as the waitlist does). Its own purpose, so a
// waitlist signature can't unsubscribe anyone here.
export function unsubscribeLinks(secret: string, functionUrl: string) {
  const sign = unsubscribeSigner("account-email-unsubscribe", secret);
  return {
    sign,
    url: async (kind: OptInKind, userId: string) =>
      `${functionUrl}?unsubscribe=${kind}.${userId}.${await sign(`${kind}:${userId}`)}`,
  };
}

// The email and person a token names, or null when it isn't one this function signed.
export async function readUnsubscribeToken(
  token: string,
  sign: (value: string) => Promise<string>,
): Promise<{ kind: OptInKind; userId: string } | null> {
  const [kind, userId, signature, ...rest] = token.split(".");
  if (rest.length > 0 || !signature || !uuidPattern.test(userId ?? "")) return null;
  if (!(OPT_IN_KINDS as readonly string[]).includes(kind)) return null;
  if (!sameSecret(signature, await sign(`${kind}:${userId}`))) return null;
  return { kind: kind as OptInKind, userId };
}

const FIXED_ORIGINS = [
  "https://getfoon.com",
  "https://www.getfoon.com",
  "http://localhost:3000",
  "http://localhost:3001",
  "http://127.0.0.1:3000",
] as const;

// Who may POST from a browser: getfoon.com, local dev, and the site ACCOUNT_EMAIL_SITE_URL points the links at (a
// staging or preview site), as parental-consent does with CONSENT_SITE_URL.
export function unsubscribeOrigins(siteUrl: string | undefined): string[] {
  let origin: string;
  try {
    origin = new URL(siteUrl ?? "").origin;
  } catch {
    return [...FIXED_ORIGINS];
  }
  return origin === "null" || (FIXED_ORIGINS as readonly string[]).includes(origin)
    ? [...FIXED_ORIGINS]
    : [...FIXED_ORIGINS, origin];
}

export interface UnsubscribeDeps {
  // Origins allowed to POST from a browser; a request with no Origin (a mail app's one-click) passes.
  allowedOrigins: readonly string[];
  siteUrl: string;
  sign(value: string): Promise<string>;
  unsubscribe(userId: string, kind: OptInKind): Promise<void>;
  // Outcomes only: never an id or an address.
  log(message: string, error?: unknown): void;
}

const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Vary": "Origin",
});

const json = (status: number, body: Record<string, unknown>, origin: string | null) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...(origin ? corsHeaders(origin) : {}) },
  });

export async function handleUnsubscribe(req: Request, token: string, deps: UnsubscribeDeps): Promise<Response> {
  if (req.method === "GET") {
    return new Response(null, {
      status: 303,
      headers: { Location: `${deps.siteUrl.replace(/\/+$/, "")}/email/unsubscribe?u=${encodeURIComponent(token)}` },
    });
  }
  const origin = req.headers.get("Origin");
  if (origin && !deps.allowedOrigins.includes(origin)) return json(403, { error: "forbidden" }, null);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: origin ? corsHeaders(origin) : {} });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" }, origin);

  const target = await readUnsubscribeToken(token, deps.sign);
  if (!target) return json(400, { error: "bad_request" }, origin);
  try {
    await deps.unsubscribe(target.userId, target.kind);
  } catch (error) {
    deps.log("account-email: unsubscribe failed", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "try_again" }, origin);
  }
  return json(200, { ok: true, kind: target.kind }, origin);
}
