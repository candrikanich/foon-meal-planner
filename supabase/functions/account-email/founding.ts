// Founding-family updates (#48, PR C), sent by Chris through the "Founding update" GitHub Action:
//   POST ?founding=preview   sends the update now, only to FOUNDING_UPDATES_PREVIEW_TO, with "[Preview]" in the subject
//   POST ?founding=send      queues it in email_outbox for every adult who opted in; the account-email run sends it
//                            under the 200-an-hour cap, each with its own unsubscribe link
// Both need FOUNDING_UPDATES_SECRET in x-founding-updates-secret, and EMAIL_POSTAL_ADDRESS (CAN-SPAM: no marketing email
// without a valid postal address). The body is {markdown} (first line "# Subject") or {subject, body}.
import { sameSecret } from "../_shared/token.ts";
import type { Email } from "../_shared/resend.ts";
import { foundingUpdateEmail, type OptInKind, parseUpdate } from "./opt_in_email.ts";

// The preview's unsubscribe link is signed for nobody, so pressing it changes nothing.
export const PREVIEW_USER = "00000000-0000-0000-0000-000000000000";

export interface FoundingDeps {
  secret: string | undefined;
  previewTo: string | undefined;
  // EMAIL_POSTAL_ADDRESS's lines; null when unset.
  postalAddress: readonly string[] | null;
  // Null when RESEND_API_KEY or ACCOUNT_EMAIL_FROM isn't set.
  send: ((email: Email) => Promise<void>) | null;
  unsubscribeUrl(kind: OptInKind, userId: string): Promise<string>;
  audience(): Promise<number>;
  queue(subject: string, body: string): Promise<{ updateId: string; queued: number; repeat: boolean } | "email_off">;
  log(message: string, error?: unknown): void;
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handleFoundingUpdate(req: Request, deps: FoundingDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const given = req.headers.get("x-founding-updates-secret");
  if (!deps.secret || !given || !sameSecret(given, deps.secret)) return json(401, { error: "unauthorized" });

  const mode = new URL(req.url).searchParams.get("founding");
  if (mode !== "preview" && mode !== "send") return json(400, { error: "mode is preview or send" });
  const update = parseUpdate(await req.json().catch(() => null));
  if (!update) return json(400, { error: "an update needs a one-line subject and a body" });
  if (!deps.postalAddress) return json(503, { error: "no_postal_address" });
  if (!deps.send) return json(503, { error: "email_off" });

  try {
    if (mode === "preview") {
      if (!deps.previewTo) return json(503, { error: "no_preview_address" });
      const message = foundingUpdateEmail(update, {
        unsubscribeUrl: await deps.unsubscribeUrl("founding_updates", PREVIEW_USER),
        postalAddress: deps.postalAddress,
      });
      await deps.send({ ...message, to: deps.previewTo, subject: `[Preview] ${message.subject}` });
      return json(200, { mode, subject: update.subject, audience: await deps.audience() });
    }
    const result = await deps.queue(update.subject, update.body);
    if (result === "email_off") return json(409, { error: "email_off" });
    return json(200, { mode, subject: update.subject, ...result });
  } catch (error) {
    deps.log(`account-email: founding ${mode} failed`, error instanceof Error ? error.message : "unknown");
    return json(500, { error: "failed" });
  }
}
