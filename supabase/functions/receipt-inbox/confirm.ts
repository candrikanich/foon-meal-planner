// Confirming a forwarding address (#237):
//   GET  ?confirm=<token>   no side effects: a redirect to getfoon.com/receipts/confirm, because mail scanners open every
//                           link in a message before the person does
//   POST ?confirm=<token>   the site page's button: confirms the address (service role; only the token's sha256 is sent)
import { sha256, tokenPattern } from "../_shared/token.ts";

export const DEFAULT_SITE_URL = "https://getfoon.com";

export type ConfirmOutcome = "confirmed" | "expired" | "unknown";

const FIXED_ORIGINS = [
  "https://getfoon.com",
  "https://www.getfoon.com",
  "http://localhost:3000",
  "http://localhost:3001",
  "http://127.0.0.1:3000",
] as const;

// Who may POST: getfoon.com, local dev, and the site RECEIPT_INBOX_SITE_URL points the links at (staging or a preview),
// as account-email's unsubscribeOrigins does.
export function confirmOrigins(siteUrl: string | undefined): string[] {
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

export interface ConfirmDeps {
  allowedOrigins: readonly string[];
  siteUrl: string;
  confirm(tokenHash: string): Promise<string>;
  // Outcome words only: never the token.
  log(message: string, detail?: unknown): void;
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

const OUTCOMES: readonly string[] = ["confirmed", "expired", "unknown"];

export async function handleConfirm(req: Request, token: string, deps: ConfirmDeps): Promise<Response> {
  if (req.method === "GET") {
    return new Response(null, {
      status: 303,
      headers: { Location: `${deps.siteUrl.replace(/\/+$/, "")}/receipts/confirm?t=${encodeURIComponent(token)}` },
    });
  }
  // Only the site's page confirms: unlike an unsubscribe, there's no mail-app one-click to let through.
  const origin = req.headers.get("Origin");
  if (!origin || !deps.allowedOrigins.includes(origin)) return json(403, { error: "forbidden" }, null);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" }, origin);
  if (!tokenPattern.test(token)) return json(400, { error: "bad_request" }, origin);

  let outcome: string;
  try {
    outcome = await deps.confirm(await sha256(token));
  } catch (error) {
    deps.log("receipt-inbox: confirming failed", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "try_again" }, origin);
  }
  deps.log("receipt-inbox: confirm", outcome);
  return json(200, { outcome: OUTCOMES.includes(outcome) ? outcome : "unknown" }, origin);
}
