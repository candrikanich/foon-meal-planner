// parental-consent: verifiable parental consent by COPPA "email plus" (#275).
//   POST {memberId, email?}  with the parent's JWT    the app: email the notice (email 1) to the parent
//   GET  ?consent=<token>                              email 1's link: only a redirect to the site's /consent page
//   POST ?consent=<token>  {decision}                  from that page: lookup, agree or refuse
//   GET  ?withdraw=<token>                             email 2's link: only a redirect to /consent/withdraw
//   POST ?withdraw=<token> {decision}                  from that page: lookup or withdraw
// A GET never changes anything, because link scanners (Safe Links, Mimecast) open every link in an email. Consent is
// active only once email 2 has gone out: agree, send email 2, then activate.
// Everything about storage and mail is behind ConsentDeps so the rules here are testable without either.
import { z } from "zod";
import type { Email } from "../_shared/resend.ts";
import { tokenPattern } from "../_shared/token.ts";
import { confirmationEmail, noticeEmail, TEXT_VERSION } from "./email.ts";

export type RequestResult =
  | { outcome: "already_consented" | "no_email" | "rate_limited" }
  | {
    outcome: "send";
    requestId: string;
    sendId: number;
    email: string;
    emailSource: "account" | "typed";
    firstName: string;
  };

export type LookupResult =
  | { outcome: "pending"; firstName: string; expiresAt: string }
  | { outcome: "confirmed" | "refused" | "expired" | "invalid" };

export type DecideResult =
  | { outcome: "confirmed" | "refused" | "expired" | "invalid" | "busy" }
  | { outcome: "send_confirmation"; requestId: string; email: string; firstName: string; decidedAt: string };

export type WithdrawLookupResult =
  | { outcome: "active"; firstName: string }
  | { outcome: "withdrawn" | "expired" | "invalid" };

// A database refusal: 28000 no active session, 42501 not a parent there, 22023 not an unclaimed kid's profile, 22000
// not an email address.
export class RefusedError extends Error {
  constructor(readonly code: string) {
    super(`refused (${code})`);
  }
}

export interface ConsentDeps {
  // Origins allowed to POST from a browser. The app's call has no Origin.
  allowedOrigins: readonly string[];
  siteUrl: string;
  // The Edge Function's own public URL, which the emailed links point at.
  functionUrl: string;
  userFromToken(jwt: string): Promise<string | null>;
  // request_parental_consent, run as the parent (their JWT), so the database checks who they are.
  request(jwt: string, input: { memberId: string; email: string | null }): Promise<RequestResult>;
  // False when the request wasn't pending any more (it was agreed, refused or ended meanwhile): the link is dead.
  markSent(input: { requestId: string; sendId: number; tokenHash: string; textVersion: string }): Promise<boolean>;
  releaseSend(input: { requestId: string; sendId: number }): Promise<void>;
  lookup(tokenHash: string): Promise<LookupResult>;
  decide(tokenHash: string, decision: "agree" | "refuse"): Promise<DecideResult>;
  releaseConfirmation(requestId: string): Promise<void>;
  activate(requestId: string, withdrawTokenHash: string): Promise<"confirmed" | "expired">;
  withdrawLookup(tokenHash: string): Promise<WithdrawLookupResult>;
  withdraw(tokenHash: string): Promise<"withdrawn" | "expired" | "invalid">;
  newToken(): string;
  sha256(value: string): Promise<string>;
  // "off" when email isn't configured (nothing sent); a send that fails throws.
  sendEmail(email: Email): Promise<"sent" | "off">;
  // Ids and outcomes only: never an email address, a name or a token.
  log(message: string, error?: unknown): void;
}

const requestSchema = z.object({
  // Any 8-4-4-4-12 id: seeded and test ids aren't all RFC 4122 versions, and the database checks it exists.
  memberId: z.guid(),
  email: z.string().trim().max(254).pipe(z.email()).optional(),
});
const consentSchema = z.object({ decision: z.enum(["lookup", "agree", "refuse"]) });
const withdrawSchema = z.object({ decision: z.enum(["lookup", "withdraw"]) });

const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Vary": "Origin",
});

function json(status: number, body: Record<string, unknown>, origin: string | null = null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...(origin ? corsHeaders(origin) : {}) },
  });
}

const redirect = (url: string) => new Response(null, { status: 303, headers: { Location: url } });

// Mails the notice and, only if that worked, records its token. If it didn't go out the reservation is released, so
// Send again works and failures never fill the limits.
async function sendNotice(deps: ConsentDeps, send: Extract<RequestResult, { outcome: "send" }>): Promise<Response> {
  const release = () =>
    deps.releaseSend({ requestId: send.requestId, sendId: send.sendId })
      .catch((error) => deps.log(`parental-consent: could not release send ${send.sendId}`, error));
  const token = deps.newToken();
  let result: "sent" | "off";
  try {
    result = await deps.sendEmail({
      to: send.email,
      ...noticeEmail({
        firstName: send.firstName,
        consentUrl: `${deps.functionUrl}?consent=${token}`,
        emailSource: send.emailSource,
      }),
    });
  } catch (error) {
    deps.log(`parental-consent: notice not sent for request ${send.requestId}`, error);
    await release();
    return json(502, { error: "send_failed" });
  }
  if (result === "off") {
    deps.log("parental-consent: email is off (RESEND_API_KEY or CONSENT_FROM unset); nothing sent");
    await release();
    return json(503, { error: "email_off" });
  }
  try {
    const recorded = await deps.markSent({
      requestId: send.requestId,
      sendId: send.sendId,
      tokenHash: await deps.sha256(token),
      textVersion: TEXT_VERSION,
    });
    if (!recorded) {
      // The request changed while the email was going out, so its link won't work. The app reloads the real state.
      deps.log(`parental-consent: notice sent for request ${send.requestId}, which was no longer pending`);
      return json(500, { error: "try_again" });
    }
  } catch (error) {
    // The email is out but its token wasn't saved, so its link won't work; the reservation lapses in 5 minutes.
    deps.log(`parental-consent: notice sent but not recorded for request ${send.requestId}`, error);
    return json(500, { error: "try_again" });
  }
  return json(200, { result: "sent", requestId: send.requestId, email: send.email, emailSource: send.emailSource });
}

async function requestConsent(req: Request, deps: ConsentDeps): Promise<Response> {
  const jwt = req.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1];
  const userId = jwt ? await deps.userFromToken(jwt).catch(() => null) : null;
  if (!jwt || !userId) return json(401, { error: "not_signed_in" });

  const parsed = requestSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    const badEmail = parsed.error.issues.some((issue) => issue.path[0] === "email");
    return json(400, { error: badEmail ? "bad_email" : "bad_request" });
  }

  let requested: RequestResult;
  try {
    requested = await deps.request(jwt, { memberId: parsed.data.memberId, email: parsed.data.email ?? null });
  } catch (error) {
    if (error instanceof RefusedError) {
      if (error.code === "28000") return json(401, { error: "not_signed_in" });
      if (error.code === "42501") return json(403, { error: "not_a_parent" });
      if (error.code === "22023") return json(409, { error: "not_eligible" });
      if (error.code === "22000") return json(400, { error: "bad_email" });
    }
    throw error;
  }
  switch (requested.outcome) {
    case "rate_limited":
      // Calm, and never which limit: the app shows its own localized "Try again in a little while."
      return json(429, { error: "rate_limited", message: "Try again in a little while." });
    case "already_consented":
    case "no_email":
      return json(200, { result: requested.outcome });
    case "send":
      return await sendNotice(deps, requested);
  }
}

// I agree: email 2 first, then the consent. If email 2 doesn't go out, the agreement stands and tapping again resends.
async function agree(deps: ConsentDeps, decided: Extract<DecideResult, { outcome: "send_confirmation" }>) {
  const release = () =>
    deps.releaseConfirmation(decided.requestId)
      .catch((error) => deps.log(`parental-consent: could not release confirmation ${decided.requestId}`, error));
  const withdrawToken = deps.newToken();
  try {
    const result = await deps.sendEmail({
      to: decided.email,
      ...confirmationEmail({
        firstName: decided.firstName,
        withdrawUrl: `${deps.functionUrl}?withdraw=${withdrawToken}`,
        agreedAt: decided.decidedAt,
      }),
    });
    if (result === "off") {
      deps.log("parental-consent: email is off (RESEND_API_KEY or CONSENT_FROM unset); consent not activated");
      await release();
      return "try_again";
    }
  } catch (error) {
    deps.log(`parental-consent: confirmation not sent for request ${decided.requestId}`, error);
    await release();
    return "try_again";
  }
  try {
    const outcome = await deps.activate(decided.requestId, await deps.sha256(withdrawToken));
    if (outcome !== "confirmed") deps.log(`parental-consent: request ${decided.requestId} ended before activation`);
    return outcome;
  } catch (error) {
    deps.log(`parental-consent: confirmation sent but consent not activated for request ${decided.requestId}`, error);
    await release();
    return "try_again";
  }
}

async function answerConsent(token: string, req: Request, deps: ConsentDeps, origin: string | null) {
  const parsed = consentSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return json(400, { error: "bad_request" }, origin);
  if (!tokenPattern.test(token)) return json(200, { result: "invalid" }, origin);
  const hash = await deps.sha256(token);
  const { decision } = parsed.data;

  if (decision === "lookup") {
    const found = await deps.lookup(hash);
    return json(
      200,
      found.outcome === "pending"
        ? { result: "pending", firstName: found.firstName, expiresAt: found.expiresAt }
        : { result: found.outcome },
      origin,
    );
  }
  const decided = await deps.decide(hash, decision);
  if (decided.outcome === "send_confirmation") {
    return json(200, { result: await agree(deps, decided) }, origin);
  }
  return json(200, { result: decided.outcome === "busy" ? "try_again" : decided.outcome }, origin);
}

async function answerWithdraw(token: string, req: Request, deps: ConsentDeps, origin: string | null) {
  const parsed = withdrawSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return json(400, { error: "bad_request" }, origin);
  if (!tokenPattern.test(token)) return json(200, { result: "invalid" }, origin);
  const hash = await deps.sha256(token);
  if (parsed.data.decision === "lookup") {
    const found = await deps.withdrawLookup(hash);
    return json(
      200,
      found.outcome === "active" ? { result: "active", firstName: found.firstName } : { result: found.outcome },
      origin,
    );
  }
  return json(200, { result: await deps.withdraw(hash) }, origin);
}

export async function handleParentalConsent(req: Request, deps: ConsentDeps): Promise<Response> {
  const url = new URL(req.url);
  const origin = req.headers.get("Origin");
  const site = (path: string) => `${deps.siteUrl}${path}`;
  const consent = url.searchParams.get("consent");
  const withdraw = url.searchParams.get("withdraw");

  try {
    if (req.method === "GET") {
      if (consent !== null) {
        return redirect(tokenPattern.test(consent) ? site(`/consent?t=${consent}`) : site("/consent/expired"));
      }
      if (withdraw !== null) {
        return redirect(
          tokenPattern.test(withdraw)
            ? site(`/consent/withdraw?t=${withdraw}`)
            : site("/consent/expired?link=withdraw"),
        );
      }
      return json(404, { error: "not_found" });
    }

    if (origin && !deps.allowedOrigins.includes(origin)) return json(403, { error: "forbidden" });
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: origin ? corsHeaders(origin) : {} });
    }
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" }, origin);

    if (consent !== null) return await answerConsent(consent, req, deps, origin);
    if (withdraw !== null) return await answerWithdraw(withdraw, req, deps, origin);
    return await requestConsent(req, deps);
  } catch (error) {
    deps.log("parental-consent: failed", error);
    return json(500, { error: "try_again" }, origin);
  }
}
