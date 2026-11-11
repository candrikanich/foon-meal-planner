// account-email: pg_cron (kick_account_email) pokes it every 5 minutes while emails are due, with a shared secret. It
// claims due rows from email_outbox (the claim resolves each address and skips what can't go), renders each, sends it
// through Resend, and marks it sent or releases it to retry. Nothing is claimed while email is off (no Resend key or
// sender), so no row is burned. Logs carry row ids and error codes only, never an address.
import { sameSecret } from "../_shared/token.ts";
import type { Email } from "../_shared/resend.ts";
import {
  formatDate,
  subscriptionEndedEmail,
  subscriptionEndingEmail,
  subscriptionStartedEmail,
  welcomeEmail,
} from "./email.ts";

export interface ClaimedEmail {
  id: string;
  kind: string;
  email: string;
  payload: Record<string, unknown> | null;
  attempts: number;
}

export interface AccountEmailDeps {
  cronSecret: string | undefined;
  siteUrl: string;
  // Null when RESEND_API_KEY or ACCOUNT_EMAIL_FROM isn't set.
  send: ((email: Email) => Promise<void>) | null;
  claim(limit: number): Promise<ClaimedEmail[]>;
  markSent(id: string): Promise<void>;
  // give_up: it never will go (a kind or payload this function can't write).
  release(id: string, errorCode: string, giveUp: boolean): Promise<void>;
  now(): number;
  log(message: string, error?: unknown): void;
}

export const BATCH_SIZE = 50;
// Well inside the 55-second pg_net timeout, and the 10-minute hold on a claimed row.
export const RUN_BUDGET_MS = 40_000;

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// The words for a row, or null when its kind or payload isn't one this function can write.
export function messageFor(row: ClaimedEmail, siteUrl: string): Omit<Email, "to"> | null {
  if (row.kind === "welcome") return welcomeEmail(siteUrl);
  const endsAt = row.payload?.ends_at;
  const date = typeof endsAt === "string" ? formatDate(endsAt) : null;
  if (!date) return null;
  const details = { trial: row.payload?.trial === true, date };
  switch (row.kind) {
    case "subscription_started":
      return subscriptionStartedEmail(details);
    case "subscription_ending":
      return subscriptionEndingEmail(details);
    case "subscription_ended":
      return subscriptionEndedEmail(details);
    default:
      return null;
  }
}

// A short code for the log and the row: Resend's status, a timeout, or "send_failed". Never the message's details.
function errorCode(error: unknown): string {
  const message = error instanceof Error ? error.message : "";
  const status = message.match(/^Resend answered (\d{3})$/)?.[1];
  if (status) return `resend_${status}`;
  if (message.startsWith("Resend didn't answer")) return "timeout";
  return "send_failed";
}

export async function handleAccountEmail(req: Request, deps: AccountEmailDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const given = req.headers.get("x-account-email-secret");
  if (!deps.cronSecret || !given || !sameSecret(given, deps.cronSecret)) return json(401, { error: "unauthorized" });
  if (!deps.send) {
    deps.log("account-email: RESEND_API_KEY or ACCOUNT_EMAIL_FROM is not set; nothing sent");
    return json(503, { error: "email_off" });
  }

  const totals = { sent: 0, failed: 0, unwritable: 0 };
  const started = deps.now();
  try {
    while (deps.now() - started < RUN_BUDGET_MS) {
      const rows = await deps.claim(BATCH_SIZE);
      for (const row of rows) {
        const message = messageFor(row, deps.siteUrl);
        if (!message) {
          deps.log(`account-email: can't write ${row.id} (${row.kind})`);
          await deps.release(row.id, "no_words", true);
          totals.unwritable += 1;
          continue;
        }
        try {
          await deps.send({ to: row.email, ...message });
        } catch (error) {
          const code = errorCode(error);
          deps.log(`account-email: ${row.id} not sent (${code})`);
          await deps.release(row.id, code, false);
          totals.failed += 1;
          continue;
        }
        await deps.markSent(row.id);
        totals.sent += 1;
      }
      if (rows.length < BATCH_SIZE) break;
    }
  } catch (error) {
    // A row claimed and not settled goes back out when its 10-minute hold lapses.
    deps.log("account-email: run failed", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "run_failed", ...totals });
  }
  return json(200, totals);
}
