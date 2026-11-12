// Forwarded email receipts (#237). Three doors, none behind the gateway's JWT check (config.toml):
//   POST (svix-* headers)        Resend's email.received webhook: store a forwarded receipt's lines (inbound.ts)
//   POST ?sender=add             the app: an adult adds a forwarding address, with their JWT (sender.ts)
//   GET/POST ?confirm=<token>    the confirmation link, and the site page's button (confirm.ts)
// Needs the service role. RESEND_API_KEY fetches received mail and, with RECEIPT_INBOX_FROM, sends confirmations;
// RECEIPT_INBOX_WEBHOOK_SECRET is the webhook's signing secret; RECEIPT_INBOX_DOMAIN overrides in.getfoon.com and
// RECEIPT_INBOX_SITE_URL overrides https://getfoon.com for the confirmation page.
import { createClient } from "@supabase/supabase-js";
import { resendConfigFromEnv, sendEmail } from "../_shared/resend.ts";
import { confirmOrigins, DEFAULT_SITE_URL, handleConfirm } from "./confirm.ts";
import { DEFAULT_INBOX_DOMAIN, fetchReceivedEmail, handleInbound } from "./inbound.ts";
import { handleAddSender, type SenderRefusal, SenderRefusedError, senderAnswerFromRow } from "./sender.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const supabaseUrl = required("SUPABASE_URL");
const serviceKey = required("SUPABASE_SERVICE_ROLE_KEY");
const anonKey = required("SUPABASE_ANON_KEY");
const session = { persistSession: false, autoRefreshToken: false };
const admin = createClient(supabaseUrl, serviceKey, { auth: session });
const apiKey = Deno.env.get("RESEND_API_KEY");
const resend = resendConfigFromEnv((key) => Deno.env.get(key), "RECEIPT_INBOX_FROM");
const send = resend ? (email: Parameters<typeof sendEmail>[1]) => sendEmail(resend, email) : null;
const siteUrl = Deno.env.get("RECEIPT_INBOX_SITE_URL") || DEFAULT_SITE_URL;
const functionUrl = `${supabaseUrl}/functions/v1/receipt-inbox`;
// Ids and outcome words only: no addresses, lines, names or tokens in logs.
const log = (message: string, detail?: unknown) => console.error(message, detail ?? "");
const refusals: readonly string[] = ["28000", "42501", "22023"];

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(name, args);
  if (error) throw error;
  return data as T;
}

Deno.serve((req) => {
  const url = new URL(req.url);
  const confirm = url.searchParams.get("confirm");
  if (confirm !== null) {
    return handleConfirm(req, confirm, {
      allowedOrigins: confirmOrigins(siteUrl),
      siteUrl,
      confirm: (tokenHash) => rpc("confirm_receipt_sender", { token_hash: tokenHash }),
      log,
    });
  }

  if (url.searchParams.get("sender") === "add") {
    return handleAddSender(req, {
      userFromToken: async (jwt) => (await admin.auth.getUser(jwt)).data.user?.id ?? null,
      send,
      functionUrl,
      // As the adult (their JWT, with the anon key), so the database checks their own rights.
      addSender: async (jwt, householdId, addressHash, hint, tokenHash) => {
        const asAdult = createClient(supabaseUrl, anonKey, {
          auth: session,
          global: { headers: { Authorization: `Bearer ${jwt}` } },
        });
        const { data, error } = await asAdult.rpc("add_receipt_sender", {
          target_household: householdId,
          address_hash: addressHash,
          address_hint: hint,
          token_hash: tokenHash,
        });
        if (error && refusals.includes(error.code)) throw new SenderRefusedError(error.code as SenderRefusal);
        if (error) throw error;
        return senderAnswerFromRow(data);
      },
      log,
    });
  }

  return handleInbound(req, {
    webhookSecret: Deno.env.get("RECEIPT_INBOX_WEBHOOK_SECRET"),
    inboxDomain: Deno.env.get("RECEIPT_INBOX_DOMAIN") || DEFAULT_INBOX_DOMAIN,
    getEmail: apiKey ? (id) => fetchReceivedEmail(apiKey, id) : null,
    record: (inboxToken, senderHash, sourceId, lines) =>
      rpc("record_forwarded_receipt", {
        inbox_token: inboxToken,
        sender_hash: senderHash,
        source_id: sourceId,
        lines,
      }),
    now: () => Date.now(),
    log,
  });
});
