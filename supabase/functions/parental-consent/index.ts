// The emailed links and the site's pages carry no Supabase JWT, so the function skips the JWT check (config.toml) and
// checks the app's JWT itself; the rules are in handler.ts. The app's request runs as the parent (their JWT, with the
// anon key); everything else needs the service role. RESEND_API_KEY and CONSENT_FROM turn email on; without them
// nothing is sent and the app is told email is off. CONSENT_SITE_URL overrides https://getfoon.com (e.g. a preview).
// CONSENT_CRON_SECRET must match Vault's consent_cron_secret, which pg_cron sends to ?renewals=1; unset, renewal emails
// never go.
// docs/parental-consent.md has the setup.
import { createClient } from "@supabase/supabase-js";
import { resendConfigFromEnv, sendEmail } from "../_shared/resend.ts";
import { newToken, sha256 } from "../_shared/token.ts";
import {
  consentOrigins,
  type DecideResult,
  handleParentalConsent,
  type LookupResult,
  RefusedError,
  type RenewalClaim,
  type WithdrawLookupResult,
} from "./handler.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const supabaseUrl = required("SUPABASE_URL");
const anonKey = required("SUPABASE_ANON_KEY");
const session = { persistSession: false, autoRefreshToken: false };
const admin = createClient(supabaseUrl, required("SUPABASE_SERVICE_ROLE_KEY"), { auth: session });
const resend = resendConfigFromEnv((key) => Deno.env.get(key), "CONSENT_FROM");

type Row = Record<string, unknown>;

async function rpc<T>(name: string, args: Row): Promise<T> {
  const { data, error } = await admin.rpc(name, args);
  if (error) throw error;
  return data as T;
}

Deno.serve((req) =>
  handleParentalConsent(req, {
    allowedOrigins: consentOrigins(Deno.env.get("CONSENT_SITE_URL")),
    siteUrl: Deno.env.get("CONSENT_SITE_URL") ?? "https://getfoon.com",
    functionUrl: `${supabaseUrl}/functions/v1/parental-consent`,
    userFromToken: async (jwt) => (await admin.auth.getUser(jwt)).data.user?.id ?? null,
    request: async (jwt, { memberId, email, wording }) => {
      const asParent = createClient(supabaseUrl, anonKey, {
        auth: session,
        global: { headers: { Authorization: `Bearer ${jwt}` } },
      });
      const { data, error } = await asParent.rpc("request_parental_consent", {
        target_member: memberId,
        email_address: email,
        wording,
      });
      if (error) {
        if (["28000", "42501", "22023", "22000"].includes(error.code)) throw new RefusedError(error.code);
        throw error;
      }
      const row = data as Row;
      return row.outcome === "send"
        ? {
          outcome: "send",
          requestId: row.request_id as string,
          sendId: row.send_id as number,
          email: row.email as string,
          emailSource: row.email_source as "account" | "typed",
          firstName: row.first_name as string,
          reason: row.reason === "renewal" ? "renewal" : "invite",
          ...(row.reason === "renewal"
            ? {
              renewal: {
                summary: (row.summary as string | null) ?? null,
                agreedBefore: (row.agreed_before as string | null) ?? null,
                // Absent from a database before 20261119000000: word it as held, as before.
                held: row.held !== false,
              },
            }
            : {}),
        }
        : { outcome: row.outcome as "already_consented" | "no_email" | "rate_limited" };
    },
    markSent: ({ requestId, sendId, tokenHash, textVersion }) =>
      rpc<boolean>("parental_consent_mark_sent", {
        p_request_id: requestId,
        p_send_id: sendId,
        p_token_hash: tokenHash,
        p_text_version: textVersion,
      }),
    releaseSend: ({ requestId, sendId }) =>
      rpc("parental_consent_release_send", { p_request_id: requestId, p_send_id: sendId }),
    lookup: async (tokenHash) => {
      const row = await rpc<Row>("parental_consent_lookup", { p_token_hash: tokenHash });
      if (row.outcome !== "pending") return { outcome: row.outcome } as LookupResult;
      const pending = { outcome: "pending", firstName: row.first_name, expiresAt: row.expires_at };
      return (row.reason === "renewal"
        ? { ...pending, renewal: { summary: row.summary ?? null, agreedBefore: row.agreed_before ?? null } }
        : pending) as LookupResult;
    },
    decide: async (tokenHash, decision) => {
      const row = await rpc<Row>("parental_consent_decide", { p_token_hash: tokenHash, p_decision: decision });
      return (row.outcome === "send_confirmation"
        ? {
          outcome: "send_confirmation",
          requestId: row.request_id,
          email: row.email,
          firstName: row.first_name,
          decidedAt: row.decided_at,
          reason: row.reason === "renewal" ? "renewal" : "invite",
        }
        : { outcome: row.outcome }) as DecideResult;
    },
    releaseConfirmation: (requestId) => rpc("parental_consent_release_confirmation", { p_request_id: requestId }),
    activate: (requestId, withdrawTokenHash) =>
      rpc("activate_parental_consent", { p_request_id: requestId, p_withdraw_token_hash: withdrawTokenHash }),
    withdrawLookup: async (tokenHash) => {
      const row = await rpc<Row>("parental_consent_withdraw_lookup", { p_token_hash: tokenHash });
      return (row.outcome === "active" ? { outcome: "active", firstName: row.first_name } : {
        outcome: row.outcome,
      }) as WithdrawLookupResult;
    },
    withdraw: (tokenHash) => rpc("withdraw_parental_consent", { p_token_hash: tokenHash }),
    cronSecret: Deno.env.get("CONSENT_CRON_SECRET"),
    claimRenewals: async (batchSize, wording) => {
      const { data, error } = await admin.rpc("claim_consent_renewal_emails", {
        batch_size: batchSize,
        wording,
      });
      if (error) {
        if (error.code === "22023") throw new RefusedError(error.code);
        throw error;
      }
      return (data as Row[]).map((row): RenewalClaim => ({
        requestId: row.request_id as string,
        sendId: row.send_id as number,
        email: row.email as string,
        firstName: row.first_name as string,
        reminder: row.reminder === true,
        summary: (row.summary as string | null) ?? null,
        agreedAt: (row.agreed_at as string | null) ?? null,
      }));
    },
    wordingOk: (wording) => rpc<boolean>("parental_wording_ok", { wording }),
    now: () => Date.now(),
    newToken,
    sha256,
    sendEmail: async (email) => {
      if (!resend) return "off";
      await sendEmail(resend, email);
      return "sent";
    },
    // A database error's message and code only: its details can quote the row, typed address included.
    log: (message, error) => {
      const { message: detail = "", code = "" } = (error ?? {}) as { message?: string; code?: string };
      console.error(message, [code, detail].filter(Boolean).join(" "));
    },
  })
);
