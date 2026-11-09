// parental-consent: verifiable parental consent by COPPA "email plus" (#275).
//   POST {memberId, email?}  with the parent's JWT    the app: email the notice (email 1) to the parent
//   GET  ?consent=<token>                              email 1's link: only a redirect to the site's /consent page
//   POST ?consent=<token>  {decision}                  from that page: lookup, agree or refuse
//   GET  ?withdraw=<token>                             email 2's link: only a redirect to /consent/withdraw
//   POST ?withdraw=<token> {decision}                  from that page: lookup or withdraw
//   POST ?renewals=1  with x-consent-cron-secret       pg_cron (kick_consent_renewals): email held kids' parents (#277)
// A GET never changes anything, because link scanners (Safe Links, Mimecast) open every link in an email. Consent is
// active only once email 2 has gone out: agree, send email 2, then activate. This function's wording (TEXT_VERSION) is
// emailed only while it's registered and satisfies the one in force (parental_wording_ok): a newer registered wording
// keeps sending through a rollout; an outdated one sends nothing and answers 503.
// Everything about storage and mail is behind ConsentDeps so the rules here are testable without either.
import { z } from "zod";
import type { Email } from "../_shared/resend.ts";
import { sameSecret, tokenPattern } from "../_shared/token.ts";
import { confirmationEmail, noticeEmail, renewalNoticeEmail, TEXT_VERSION } from "./email.ts";

export type RequestResult =
  | { outcome: "already_consented" | "no_email" | "rate_limited" }
  | {
    outcome: "send";
    requestId: string;
    sendId: number;
    email: string;
    emailSource: "account" | "typed";
    firstName: string;
    // renewal: the kid's consent is active but was given to older wording.
    reason: "invite" | "renewal";
    // A renewal's what changed, when a parent agreed before, and whether the kid is held yet.
    renewal?: RenewalRequest;
  };

export interface Renewal {
  // The registry's "what changed" since the wording a parent agreed to, up to the one asked for.
  summary: string | null;
  // When a parent last agreed for this kid (ISO).
  agreedBefore: string | null;
  // Whether the kid had signed in on their own device; null when the database didn't say.
  wasLinked: boolean | null;
}

// What the app's renewal request gets back for its email, as the cron's claim does.
export interface RenewalRequest extends Renewal {
  // False when the wording changed but the hourly job hasn't signed the kid out yet.
  held: boolean;
}

export type LookupResult =
  | { outcome: "pending"; firstName: string; expiresAt: string; renewal?: Renewal }
  | { outcome: "confirmed" | "withdrawn" | "refused" | "already_consented" | "expired" | "invalid" };

// parental_consent_lookup's answer. A renewal's fields are absent from a database before 20261119000000: null.
export function lookupFromRow(row: Record<string, unknown>): LookupResult {
  if (row.outcome !== "pending") return { outcome: row.outcome } as LookupResult;
  const pending = {
    outcome: "pending" as const,
    firstName: row.first_name as string,
    expiresAt: row.expires_at as string,
  };
  if (row.reason !== "renewal") return pending;
  return {
    ...pending,
    renewal: {
      summary: (row.summary as string | null) ?? null,
      agreedBefore: (row.agreed_before as string | null) ?? null,
      wasLinked: typeof row.was_linked === "boolean" ? row.was_linked : null,
    },
  };
}

// One renewal email claim_consent_renewal_emails reserved.
export interface RenewalClaim {
  requestId: string;
  sendId: number;
  email: string;
  firstName: string;
  reminder: boolean;
  // What changed since the wording a parent agreed to, up to the wording being sent.
  summary: string | null;
  agreedAt: string | null;
  // Whether the kid had signed in on their own device; null when the database didn't say.
  wasLinked: boolean | null;
}

export type DecideResult =
  | { outcome: "confirmed" | "withdrawn" | "refused" | "already_consented" | "expired" | "invalid" | "busy" }
  | {
    outcome: "send_confirmation";
    requestId: string;
    email: string;
    firstName: string;
    decidedAt: string;
    reason: "invite" | "renewal";
  };

export type WithdrawLookupResult =
  | { outcome: "active"; firstName: string }
  | { outcome: "withdrawn" | "expired" | "invalid" };

// A database refusal: 28000 no active session, 42501 not a parent there, 22023 not an unclaimed kid's profile (or, from
// claimRenewals, a wording that isn't satisfying), 22000 not an email address.
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
  // request_parental_consent, run as the parent (their JWT), so the database checks who they are. `wording` is the one
  // this function emails, so a renewal's "what changed" describes it.
  request(jwt: string, input: { memberId: string; email: string | null; wording: string }): Promise<RequestResult>;
  // False when the request wasn't pending any more (it was agreed, refused or ended meanwhile): the link is dead.
  markSent(input: { requestId: string; sendId: number; tokenHash: string; textVersion: string }): Promise<boolean>;
  releaseSend(input: { requestId: string; sendId: number }): Promise<void>;
  lookup(tokenHash: string): Promise<LookupResult>;
  decide(tokenHash: string, decision: "agree" | "refuse"): Promise<DecideResult>;
  releaseConfirmation(requestId: string): Promise<void>;
  activate(requestId: string, withdrawTokenHash: string): Promise<"confirmed" | "already_consented" | "expired">;
  withdrawLookup(tokenHash: string): Promise<WithdrawLookupResult>;
  withdraw(tokenHash: string): Promise<"withdrawn" | "expired" | "invalid">;
  // CONSENT_CRON_SECRET: what pg_cron sends in x-consent-cron-secret. Unset, renewal mode refuses every call.
  cronSecret: string | undefined;
  // claim_consent_renewal_emails: reserves up to `batchSize` renewal emails of `wording`. RefusedError("22023"), with
  // nothing reserved, when that wording isn't registered or doesn't satisfy the one in force.
  claimRenewals(batchSize: number, wording: string): Promise<RenewalClaim[]>;
  // parental_wording_ok: whether `wording` is registered and satisfies the one in force.
  wordingOk(wording: string): Promise<boolean>;
  // Milliseconds, for the renewal run's time budget.
  now(): number;
  newToken(): string;
  sha256(value: string): Promise<string>;
  // "off" when email isn't configured (nothing sent); a send that fails throws.
  sendEmail(email: Email): Promise<"sent" | "off">;
  // Ids and outcomes only: never an email address, a name or a token.
  log(message: string, error?: unknown): void;
}

const FIXED_ORIGINS = [
  "https://getfoon.com",
  "https://www.getfoon.com",
  "http://localhost:3000",
  "http://localhost:3001",
  "http://127.0.0.1:3000",
] as const;

// The site's origins, plus CONSENT_SITE_URL's when it points the links at a preview (its origin only, never a path).
export function consentOrigins(siteUrl: string | undefined): string[] {
  if (!siteUrl) return [...FIXED_ORIGINS];
  let origin: string;
  try {
    origin = new URL(siteUrl).origin;
  } catch {
    return [...FIXED_ORIGINS];
  }
  return origin === "null" || FIXED_ORIGINS.includes(origin as typeof FIXED_ORIGINS[number])
    ? [...FIXED_ORIGINS]
    : [...FIXED_ORIGINS, origin];
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

type Reservation = { requestId: string; sendId: number };
type Delivery = "sent" | "send_failed" | "email_off" | "not_pending" | "not_recorded";

const releaseReservation = (deps: ConsentDeps, reservation: Reservation) =>
  deps.releaseSend(reservation)
    .catch((error) => deps.log(`parental-consent: could not release send ${reservation.sendId}`, error));

// Mails a notice and, only if that worked, records its token and wording. If it didn't go out the reservation is
// released, so Send again (or the next renewal run) works and failures never fill the limits.
async function deliverNotice(
  deps: ConsentDeps,
  reservation: Reservation,
  to: string,
  compose: (consentUrl: string) => Omit<Email, "to">,
): Promise<Delivery> {
  const token = deps.newToken();
  let result: "sent" | "off";
  try {
    result = await deps.sendEmail({ to, ...compose(`${deps.functionUrl}?consent=${token}`) });
  } catch (error) {
    deps.log(`parental-consent: notice not sent for request ${reservation.requestId}`, error);
    await releaseReservation(deps, reservation);
    return "send_failed";
  }
  if (result === "off") {
    deps.log("parental-consent: email is off (RESEND_API_KEY or CONSENT_FROM unset); nothing sent");
    await releaseReservation(deps, reservation);
    return "email_off";
  }
  try {
    const recorded = await deps.markSent({
      ...reservation,
      tokenHash: await deps.sha256(token),
      textVersion: TEXT_VERSION,
    });
    if (!recorded) {
      // The request changed while the email was going out, so its link won't work. The app reloads the real state.
      deps.log(`parental-consent: notice sent for request ${reservation.requestId}, which was no longer pending`);
      return "not_pending";
    }
  } catch (error) {
    // The email is out but its token wasn't saved, so its link won't work. The send still counts toward the daily and
    // hourly limits.
    deps.log(`parental-consent: notice sent but not recorded for request ${reservation.requestId}`, error);
    return "not_recorded";
  }
  return "sent";
}

const logOutdatedWording = (deps: ConsentDeps) =>
  deps.log(`parental-consent: ${TEXT_VERSION} isn't registered or is older than the wording in force; nothing sent`);

async function sendNotice(deps: ConsentDeps, send: Extract<RequestResult, { outcome: "send" }>): Promise<Response> {
  const reservation = { requestId: send.requestId, sendId: send.sendId };
  let wordingOk: boolean;
  try {
    wordingOk = await deps.wordingOk(TEXT_VERSION);
  } catch (error) {
    deps.log(`parental-consent: wording not checked for request ${send.requestId}`, error);
    await releaseReservation(deps, reservation);
    return json(500, { error: "try_again" });
  }
  if (!wordingOk) {
    logOutdatedWording(deps);
    await releaseReservation(deps, reservation);
    return json(503, { error: "wording_outdated" });
  }
  const delivery = await deliverNotice(deps, reservation, send.email, (consentUrl) =>
    send.reason === "renewal"
      // An older database's answer has no renewal fields: the email words itself without them, as if held.
      ? renewalNoticeEmail({
        firstName: send.firstName,
        consentUrl,
        emailSource: send.emailSource,
        summary: send.renewal?.summary ?? null,
        agreedBefore: send.renewal?.agreedBefore ?? null,
        held: send.renewal?.held ?? true,
        wasLinked: send.renewal?.wasLinked ?? null,
        reminder: false,
      })
      : noticeEmail({ firstName: send.firstName, consentUrl, emailSource: send.emailSource }));
  switch (delivery) {
    case "send_failed":
      return json(502, { error: "send_failed" });
    case "email_off":
      return json(503, { error: "email_off" });
    case "not_pending":
    case "not_recorded":
      return json(500, { error: "try_again" });
    case "sent":
      return json(200, { result: "sent", requestId: send.requestId, email: send.email, emailSource: send.emailSource });
  }
}

// 50 a run, every 15 minutes, stays inside the 200-an-hour overall cap the claim also checks.
export const RENEWAL_BATCH = 50;
// pg_net gives up on the poke after 55 s; claims not sent by 40 s are released for the next run, and each send has its
// own 10 s timeout (_shared/resend.ts), so a run ends well inside that.
export const RENEWAL_BUDGET_MS = 40_000;

// pg_cron's poke: email the renewal notice, in this function's wording, to each parent claimed. The claim refuses a
// wording that isn't registered or is outdated (the function wasn't deployed with the new wording yet), reserving
// nothing, and the run answers 503 so it shows in the logs. A send that fails, or isn't reached in time, is released;
// the hold's round clock starts only when parental_consent_mark_sent records an email as sent.
async function sendRenewals(req: Request, deps: ConsentDeps): Promise<Response> {
  const given = req.headers.get("x-consent-cron-secret");
  if (!deps.cronSecret || !given || !sameSecret(given, deps.cronSecret)) return json(401, { error: "unauthorized" });

  const startedAt = deps.now();
  let claims: RenewalClaim[];
  try {
    claims = await deps.claimRenewals(RENEWAL_BATCH, TEXT_VERSION);
  } catch (error) {
    if (error instanceof RefusedError && error.code === "22023") {
      logOutdatedWording(deps);
      return json(503, { error: "wording_outdated" });
    }
    throw error;
  }
  const totals = { sent: 0, failed: 0, unrecorded: 0, deferred: 0 };
  let emailOff = false;
  for (const claim of claims) {
    const reservation = { requestId: claim.requestId, sendId: claim.sendId };
    if (emailOff || deps.now() - startedAt >= RENEWAL_BUDGET_MS) {
      await releaseReservation(deps, reservation);
      totals[emailOff ? "failed" : "deferred"] += 1;
      continue;
    }
    const delivery = await deliverNotice(deps, reservation, claim.email, (consentUrl) =>
      renewalNoticeEmail({
        firstName: claim.firstName,
        consentUrl,
        emailSource: "account",
        summary: claim.summary,
        agreedBefore: claim.agreedAt,
        // Only a held kid's parents are claimed.
        held: true,
        wasLinked: claim.wasLinked,
        reminder: claim.reminder,
      }));
    if (delivery === "sent") totals.sent += 1;
    else if (delivery === "not_pending" || delivery === "not_recorded") totals.unrecorded += 1;
    else totals.failed += 1;
    if (delivery === "email_off") emailOff = true;
  }
  if (totals.deferred > 0) deps.log(`parental-consent: ran out of time; ${totals.deferred} renewals left for next run`);
  if (emailOff) return json(503, { error: "email_off", ...totals });
  return json(200, totals);
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
    requested = await deps.request(jwt, {
      memberId: parsed.data.memberId,
      email: parsed.data.email ?? null,
      wording: TEXT_VERSION,
    });
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
        renewal: decided.reason === "renewal",
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
    if (found.outcome !== "pending") return json(200, { result: found.outcome }, origin);
    const pending = { result: "pending", firstName: found.firstName, expiresAt: found.expiresAt };
    return json(
      200,
      found.renewal
        ? {
          ...pending,
          reason: "renewal",
          summary: found.renewal.summary,
          agreedBefore: found.renewal.agreedBefore,
          wasLinked: found.renewal.wasLinked,
        }
        : pending,
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

    if (url.searchParams.has("renewals")) return await sendRenewals(req, deps);
    if (consent !== null) return await answerConsent(consent, req, deps, origin);
    if (withdraw !== null) return await answerWithdraw(withdraw, req, deps, origin);
    return await requestConsent(req, deps);
  } catch (error) {
    deps.log("parental-consent: failed", error);
    return json(500, { error: "try_again" }, origin);
  }
}
