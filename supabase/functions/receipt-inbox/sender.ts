// Adding a forwarding address (#237): POST ?sender=add {household_id, address} with an adult's JWT, from the app.
// add_receipt_sender runs as that adult, so the database decides whether they may. It gets only the address's sha256,
// a hint for the app to show, and the sha256 of the link's token; the address itself goes only to Resend, for the
// confirmation email, and is never stored or logged.
import { z } from "zod";
import { transactionalEmail } from "../_shared/email_layout.ts";
import type { Email } from "../_shared/resend.ts";
import { newToken, sha256 } from "../_shared/token.ts";

export type SenderOutcome = "send" | "confirmed" | "taken" | "too_many" | "rate_limited";
const OUTCOMES: readonly SenderOutcome[] = ["send", "confirmed", "taken", "too_many", "rate_limited"];

export type SenderAnswer = { outcome: "send"; id: string } | { outcome: Exclude<SenderOutcome, "send"> };

// The database's refusals: 28000 not signed in, 42501 not an adult in that household, 22023 a hash or hint it won't take.
export type SenderRefusal = "28000" | "42501" | "22023";
export class SenderRefusedError extends Error {
  constructor(readonly code: SenderRefusal) {
    super(`refused ${code}`);
  }
}

const refusalStatus: Record<SenderRefusal, [number, string]> = {
  "28000": [401, "not_signed_in"],
  "42501": [403, "not_an_adult"],
  "22023": [400, "bad_request"],
};

export interface AddSenderDeps {
  userFromToken(jwt: string): Promise<string | null>;
  // Null when RESEND_API_KEY or RECEIPT_INBOX_FROM isn't set.
  send: ((email: Email) => Promise<void>) | null;
  addSender(jwt: string, householdId: string, addressHash: string, hint: string, tokenHash: string): Promise<SenderAnswer>;
  // This function's URL; the link is ${functionUrl}?confirm=<token>.
  functionUrl: string;
  // Row ids and outcome words only.
  log(message: string, detail?: unknown): void;
}

export const addSenderSchema = z.object({
  household_id: z.guid(),
  address: z.string().trim().toLowerCase().max(254).pipe(z.email()),
});

// add_receipt_sender's answer as the handler reads it; one it doesn't know is an error.
export function senderAnswerFromRow(row: Record<string, unknown> | null): SenderAnswer {
  const outcome = row?.outcome;
  if (outcome === "send" && typeof row?.id === "string") return { outcome, id: row.id };
  if (typeof outcome === "string" && outcome !== "send" && (OUTCOMES as readonly string[]).includes(outcome)) {
    return { outcome: outcome as Exclude<SenderOutcome, "send"> };
  }
  throw new Error(`unexpected outcome ${String(outcome)}`);
}

// "c•••@gmail.com": enough for the family to tell their addresses apart, within the database's 80 characters.
export function addressHint(address: string): string {
  const at = address.lastIndexOf("@");
  const hint = `${Array.from(address)[0]}•••@${address.slice(at + 1)}`;
  return hint.length > 80 ? `${hint.slice(0, 79)}…` : hint;
}

export const SENDER_SUBJECT = "Confirm your address for Foon receipts";

export function senderEmail(link: string): Omit<Email, "to"> {
  return transactionalEmail(SENDER_SUBJECT, [
    "Hi,",
    "Someone in your family on Foon added this address, so receipts forwarded from it go to the family's Foon.",
    `If it's yours, open this link to confirm: ${link}`,
    "The link works for a day.",
    "If this wasn't you, ignore this email and nothing changes.",
  ]);
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handleAddSender(req: Request, deps: AddSenderDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const jwt = req.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1];
  const userId = jwt ? await deps.userFromToken(jwt).catch(() => null) : null;
  if (!jwt || !userId) return json(401, { error: "not_signed_in" });

  const parsed = addSenderSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    const badAddress = parsed.error.issues.some((issue) => issue.path[0] === "address");
    return json(400, { error: badAddress ? "bad_address" : "bad_request" });
  }
  // Checked before the database, so a link that can't be sent isn't counted against the address's five.
  if (!deps.send) {
    deps.log("receipt-inbox: RESEND_API_KEY or RECEIPT_INBOX_FROM is not set; no confirmation sent");
    return json(503, { outcome: "email_off" });
  }

  const { household_id: householdId, address } = parsed.data;
  const token = newToken();
  const tokenHash = await sha256(token);
  let answer: SenderAnswer;
  try {
    answer = await deps.addSender(jwt, householdId, await sha256(address), addressHint(address), tokenHash);
  } catch (error) {
    if (error instanceof SenderRefusedError) {
      const [status, code] = refusalStatus[error.code];
      return json(status, { error: code });
    }
    deps.log("receipt-inbox: adding a sender failed", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "failed" });
  }
  if (answer.outcome !== "send") return json(200, { outcome: answer.outcome });

  try {
    await deps.send({
      to: address,
      ...senderEmail(`${deps.functionUrl}?confirm=${encodeURIComponent(token)}`),
      idempotencyKey: `receipt-sender-${answer.id}-${tokenHash.slice(0, 16)}`,
    });
  } catch (error) {
    // sendEmail's errors name only Resend's status or a timeout, never the address.
    deps.log(`receipt-inbox: confirmation for ${answer.id} not sent`, error instanceof Error ? error.message : "unknown");
    return json(502, { error: "send_failed" });
  }
  return json(200, { outcome: "send" });
}
