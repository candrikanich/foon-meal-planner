// A receipt forwarded to a household's address (#237). Resend receives the mail and POSTs an email.received webhook;
// its body isn't in the webhook, so it's fetched by id, checked, turned into lines (text.ts), and handed to
// record_forwarded_receipt, which knows the address and the confirmed senders. Every answer but a transient failure is
// 200, so Resend doesn't retry mail that will never be stored; a 500 asks it to try again.
import { sha256 } from "../_shared/token.ts";
import { svixHeaders, verifySvix } from "./svix.ts";
import { receiptLines } from "./text.ts";

export const DEFAULT_INBOX_DOMAIN = "in.getfoon.com";
// Bigger than any receipt; past it, it's something else and isn't read.
export const MAX_BODY_CHARS = 500_000;
export const FETCH_TIMEOUT_MS = 10_000;

export type RecordOutcome = "stored" | "duplicate" | "unknown_inbox" | "unknown_sender" | "over_limit" | "bad_lines";

export interface ReceivedEmail {
  from?: string | null;
  text?: string | null;
  html?: string | null;
  authentication?: { spf?: string; dkim?: string; dmarc?: string } | null;
}

// Resend didn't answer, answered 5xx or 429: worth Resend's retry.
export class TransientError extends Error {}

export interface InboundDeps {
  // RECEIPT_INBOX_WEBHOOK_SECRET, "whsec_…".
  webhookSecret: string | undefined;
  inboxDomain: string;
  // Null when Resend has no such email (404). Throws TransientError when it's worth trying again.
  getEmail: ((id: string) => Promise<ReceivedEmail | null>) | null;
  record(inboxToken: string, senderHash: string, sourceId: string, lines: string[]): Promise<string>;
  now(): number;
  // Email ids and outcome words only: never an address, a line or the inbox token.
  log(message: string, detail?: unknown): void;
}

export async function fetchReceivedEmail(
  apiKey: string,
  id: string,
  get: typeof fetch = fetch,
  timeoutMs = FETCH_TIMEOUT_MS,
): Promise<ReceivedEmail | null> {
  let response: Response;
  try {
    response = await get(`https://api.resend.com/emails/receiving/${encodeURIComponent(id)}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    throw new TransientError(error instanceof Error ? error.name : "fetch failed");
  }
  if (response.status === 404) return null;
  if (response.status === 429 || response.status >= 500) throw new TransientError(`Resend answered ${response.status}`);
  if (!response.ok) throw new Error(`Resend answered ${response.status}`);
  return await response.json() as ReceivedEmail;
}

// "Name <a@b.com>" or a bare address, lowercased.
export function addressOf(value: string | null | undefined): string | null {
  const raw = (value ?? "").match(/<([^<>]+)>\s*$/)?.[1] ?? value ?? "";
  const address = raw.trim().toLowerCase();
  // More than one address in From can't be matched to the domain DMARC checked, so it's no sender at all. A quoted
  // display name may itself be an address ("a@b.com" <a@b.com>), so quotes don't count.
  if ((value ?? "").replace(/"[^"]*"/g, "").split("@").length > 2) return null;
  return /^[^\s@]+@[^\s@]+$/.test(address) ? address : null;
}

const escapeRegExp = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// The household token of the first recipient that's one of Foon's inbox addresses.
export function inboxToken(recipients: unknown[], domain: string): string | null {
  const pattern = new RegExp(`^r-([0-9a-f]{16})@${escapeRegExp(domain.toLowerCase())}$`);
  for (const recipient of recipients) {
    if (typeof recipient !== "string") continue;
    const match = addressOf(recipient)?.match(pattern);
    if (match) return match[1];
  }
  return null;
}

const asList = (value: unknown): unknown[] => Array.isArray(value) ? value : value === undefined ? [] : [value];

const ok = (result: string) =>
  new Response(JSON.stringify({ result }), { status: 200, headers: { "Content-Type": "application/json" } });
const fail = (status: number, error: string) =>
  new Response(JSON.stringify({ error }), { status, headers: { "Content-Type": "application/json" } });

// The sender check below trusts the From address only when its domain sent the mail. DMARC pass says so. So does a
// DKIM pass under a gray DMARC (a domain with no policy or p=none, which is Gmail): Resend reports DKIM as pass only
// when the signing domain matches From, and grays it otherwise (docs, checked 2026-11-13). SPF alone isn't enough,
// since it checks the envelope sender, which needn't match From.
export function fromDomainSentIt(authentication: ReceivedEmail["authentication"]): boolean {
  if (authentication?.dmarc === "pass") return true;
  return authentication?.dmarc === "gray" && authentication.dkim === "pass";
}

const AUTHENTICATION_RESULTS = new Set(["pass", "fail", "gray", "processing_failed", "unknown"]);

// Only Resend's result words reach the log; anything else is "other".
function authenticationSummary(authentication: ReceivedEmail["authentication"]): string {
  if (!authentication) return "no authentication result";
  const word = (value: string | undefined) => value && AUTHENTICATION_RESULTS.has(value) ? value : "other";
  const { spf, dkim, dmarc } = authentication;
  return `spf=${word(spf)} dkim=${word(dkim)} dmarc=${word(dmarc)}`;
}

export async function handleInbound(req: Request, deps: InboundDeps): Promise<Response> {
  if (req.method !== "POST") return fail(405, "method_not_allowed");
  // 503 rather than 200 while it's being set up, so Resend holds the mail and retries.
  if (!deps.webhookSecret || !deps.getEmail) {
    deps.log("receipt-inbox: RECEIPT_INBOX_WEBHOOK_SECRET or RESEND_API_KEY is not set");
    return fail(503, "not_configured");
  }
  const body = await req.text();
  if (!await verifySvix(deps.webhookSecret, svixHeaders(req.headers), body, deps.now())) {
    return fail(401, "bad_signature");
  }

  let event: { type?: unknown; data?: Record<string, unknown> };
  try {
    event = JSON.parse(body);
  } catch {
    return fail(400, "bad_request");
  }
  if (event?.type !== "email.received") return ok("ignored");
  const emailId = event.data?.email_id;
  if (typeof emailId !== "string" || emailId.length < 1 || emailId.length > 100) {
    deps.log("receipt-inbox: email.received without an email id");
    return ok("ignored");
  }

  const token = inboxToken([...asList(event.data?.to), ...asList(event.data?.received_for)], deps.inboxDomain);
  if (!token) {
    deps.log("receipt-inbox: no inbox address", emailId);
    return ok("dropped");
  }

  let email: ReceivedEmail | null;
  try {
    email = await deps.getEmail(emailId);
  } catch (error) {
    deps.log(`receipt-inbox: fetching ${emailId} failed`, error instanceof Error ? error.message : "unknown");
    return fail(500, "try_again");
  }
  if (!email) {
    deps.log("receipt-inbox: Resend has no such email", emailId);
    return ok("dropped");
  }
  // Resend keeps received mail for 30 days and has no API to delete it (checked 2026-11-12); once it does, each
  // email is deleted here, whatever happens to it below.

  if (!fromDomainSentIt(email.authentication)) {
    deps.log(`receipt-inbox: dropped ${emailId}`, authenticationSummary(email.authentication));
    return ok("dropped");
  }
  const sender = addressOf(email.from);
  if (!sender) {
    deps.log(`receipt-inbox: dropped ${emailId}`, "no sender address");
    return ok("dropped");
  }
  if ((email.text?.length ?? 0) + (email.html?.length ?? 0) > MAX_BODY_CHARS) {
    deps.log(`receipt-inbox: dropped ${emailId}`, "too big");
    return ok("dropped");
  }
  const lines = receiptLines(email.text, email.html);
  if (lines.length === 0) {
    deps.log(`receipt-inbox: dropped ${emailId}`, "no lines");
    return ok("dropped");
  }

  let outcome: string;
  try {
    outcome = await deps.record(token, await sha256(sender), emailId, lines);
  } catch (error) {
    deps.log(`receipt-inbox: recording ${emailId} failed`, error instanceof Error ? error.message : "unknown");
    return fail(500, "try_again");
  }
  deps.log(`receipt-inbox: ${emailId}`, outcome);
  return ok(outcome);
}
