// Emailing an adult's invite (#48 PR B):
//   POST ?invite=1 {memberId, code, email}  with a parent's JWT    the app: email this invite to the address typed
// reserve_invite_email (run as the parent) checks they may invite that profile, that it's an unclaimed adult's, that the
// code is its open invite, that account email is on, and the limits; it records the send (never the address) and gives
// back what the email says. The address goes only to Resend, for this one email: it's never stored, logged or echoed.
import { z } from "zod";
import { transactionalEmail } from "../_shared/email_layout.ts";
import type { Email } from "../_shared/resend.ts";
import { formatDate } from "./email.ts";

export type InviteRefusal = "kid" | "not_invitable" | "email_off" | "wrong_code" | "rate_limited";

export type InviteReservation =
  | { outcome: InviteRefusal }
  | {
    outcome: "send";
    sendId: number;
    code: string;
    firstName: string;
    inviter: string | null;
    household: string;
    expiresAt: string;
    timeZone: string | null;
  };

// The database's refusals: 28000 not signed in, 42501 not a parent in that household (or no such profile).
export class InviteRefusedError extends Error {
  constructor(readonly code: "28000" | "42501") {
    super(`refused ${code}`);
  }
}

export interface InviteEmailDeps {
  userFromToken(jwt: string): Promise<string | null>;
  // Null when RESEND_API_KEY or ACCOUNT_EMAIL_FROM isn't set.
  send: ((email: Email) => Promise<void>) | null;
  reserve(jwt: string, memberId: string, code: string): Promise<InviteReservation>;
  // Ids and codes only: never the address, a name or the invite code.
  log(message: string, error?: unknown): void;
}

// The same link as the app's InviteCode.link(for:): www, because Apple doesn't follow getfoon.com's redirect to the
// association file.
export const inviteLink = (code: string) => `https://www.getfoon.com/invite?code=${encodeURIComponent(code)}`;

// What the app is told for each refusal.
const refusals: Record<InviteRefusal, number> = {
  kid: 409,
  not_invitable: 409,
  wrong_code: 409,
  email_off: 503,
  rate_limited: 429,
};

// What reserve_invite_email answered, as the handler reads it; an answer it doesn't know is an error.
export function reservationFromRow(row: Record<string, unknown> | null): InviteReservation {
  const outcome = row?.outcome;
  if (row && outcome === "send") {
    return {
      outcome,
      sendId: Number(row.send_id),
      code: String(row.code),
      firstName: String(row.first_name ?? ""),
      inviter: typeof row.inviter === "string" ? row.inviter : null,
      household: String(row.household ?? ""),
      expiresAt: String(row.expires_at),
      timeZone: typeof row.time_zone === "string" ? row.time_zone : null,
    };
  }
  if (typeof outcome === "string" && Object.hasOwn(refusals, outcome)) return { outcome: outcome as InviteRefusal };
  throw new Error(`unexpected outcome ${String(outcome)}`);
}

export const inviteSchema = z.object({
  // Any 8-4-4-4-12 id: seeded and test ids aren't all RFC 4122 versions, and the database checks it exists.
  memberId: z.guid(),
  // As people type it: the prefix, dashes and spaces are optional. The database checks it's the invite's.
  code: z.string().trim().min(8).max(32).regex(/^[A-Za-z0-9 -]+$/),
  email: z.string().trim().max(254).pipe(z.email()),
});

// Anything that reads as a link, an address or a number to call: a scheme (https://), www., an @, a dotted domain
// (foo.com), a spelled-out one ("paypal dot com"), or seven or more digits (a phone number).
const LINK_LIKE =
  /[a-z][a-z0-9+.-]*:\/\/|www\.|@|[\p{L}\p{N}-]+\.[\p{L}]{2,}|\bdot\s+(?:com|net|org|co|io|app)\b|\d(?:[\s().+-]*\d){6,}/iu;

// Fixed, so nothing the family typed reaches the subject line.
export const INVITE_SUBJECT = "You're invited to join a family on Foon";
const NOT_SHOWN = "(not shown)";

// A name the family typed, safe to show as plain text: no control characters or line breaks, at most 60 characters,
// and never something that looks like a link or an address (an email to any address mustn't carry someone's URL).
export function plainName(value: string | null | undefined): string {
  const cleaned = (value ?? "").replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/gu, " ").replace(/\s+/g, " ").trim();
  if (!cleaned || LINK_LIKE.test(cleaned)) return NOT_SHOWN;
  return cleaned.length > 60 ? `${cleaned.slice(0, 59).trimEnd()}…` : cleaned;
}

// Our own words, with the family's names only as labeled plain text (escaped in the HTML), and our own link only.
export function inviteEmail(invite: Extract<InviteReservation, { outcome: "send" }>): Omit<Email, "to"> {
  const expires = formatDate(invite.expiresAt, invite.timeZone ?? undefined);
  return transactionalEmail(INVITE_SUBJECT, [
    "Hi,",
    "Someone in a family on Foon invited you to join them. Foon is a dinner planner for the whole family: everyone " +
    "can suggest dishes, rate dinners and offer to cook, so planning isn't one person's job.",
    {
      list: [
        `Invited by: ${plainName(invite.inviter)}`,
        `Family: ${plainName(invite.household)}`,
        `Invite for: ${plainName(invite.firstName)}`,
      ],
    },
    `To join on your iPhone, iPad or Mac, open this link: ${inviteLink(invite.code)}`,
    `Or get Foon from the App Store, sign in with Apple, and enter this code: ${invite.code}`,
    expires
      ? `The code works once, and expires on ${expires}.`
      : "The code works once, and expires 7 days after it was made.",
    "You're getting this because someone in that family typed your address in Foon to send you this invite. Foon used " +
    "it only to send this email and didn't keep it. If you weren't expecting it, you can ignore it.",
  ]);
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handleInviteEmail(req: Request, deps: InviteEmailDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const jwt = req.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1];
  const userId = jwt ? await deps.userFromToken(jwt).catch(() => null) : null;
  if (!jwt || !userId) return json(401, { error: "not_signed_in" });

  const parsed = inviteSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    const badEmail = parsed.error.issues.some((issue) => issue.path[0] === "email");
    return json(400, { error: badEmail ? "bad_email" : "bad_request" });
  }
  // Checked before the reservation, so a send that can't go isn't counted.
  if (!deps.send) {
    deps.log("account-email: RESEND_API_KEY or ACCOUNT_EMAIL_FROM is not set; invite not sent");
    return json(503, { error: "email_off" });
  }

  let reservation: InviteReservation;
  try {
    reservation = await deps.reserve(jwt, parsed.data.memberId, parsed.data.code);
  } catch (error) {
    if (error instanceof InviteRefusedError) {
      return error.code === "28000" ? json(401, { error: "not_signed_in" }) : json(403, { error: "not_a_parent" });
    }
    deps.log("account-email: invite check failed", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "failed" });
  }
  if (reservation.outcome !== "send") {
    return json(refusals[reservation.outcome], { error: reservation.outcome });
  }

  try {
    await deps.send({
      to: parsed.data.email,
      ...inviteEmail(reservation),
      idempotencyKey: `invite-email/${reservation.sendId}`,
    });
  } catch (error) {
    // sendEmail's errors name only Resend's status or a timeout, never the address.
    deps.log(`account-email: invite ${reservation.sendId} not sent`, error instanceof Error ? error.message : "unknown");
    return json(502, { error: "send_failed" });
  }
  return json(200, { result: "sent" });
}
