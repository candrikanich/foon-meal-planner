// Sends Foon's queued account emails (#48): the owner's welcome and subscription notices. pg_cron calls it through
// pg_net with ACCOUNT_EMAIL_CRON_SECRET in x-account-email-secret, so it skips the JWT check (config.toml). Needs the
// service role. RESEND_API_KEY and ACCOUNT_EMAIL_FROM turn email on; ACCOUNT_EMAIL_SITE_URL overrides
// https://getfoon.com for links. Nothing is claimed until app_config.account_email_enabled is on.
// docs/account-email.md has the setup.
import { createClient } from "@supabase/supabase-js";
import { resendConfigFromEnv, sendEmail } from "../_shared/resend.ts";
import { DEFAULT_SITE_URL } from "./email.ts";
import { type ClaimedEmail, handleAccountEmail } from "./handler.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const admin = createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const resend = resendConfigFromEnv((key) => Deno.env.get(key), "ACCOUNT_EMAIL_FROM");

Deno.serve((req) =>
  handleAccountEmail(req, {
    cronSecret: Deno.env.get("ACCOUNT_EMAIL_CRON_SECRET"),
    siteUrl: Deno.env.get("ACCOUNT_EMAIL_SITE_URL") || DEFAULT_SITE_URL,
    send: resend ? (email) => sendEmail(resend, email) : null,
    claim: async (limit) => {
      const { data, error } = await admin.rpc("claim_account_emails", { batch_size: limit });
      if (error) throw error;
      return data as ClaimedEmail[];
    },
    markSent: async (id) => {
      const { error } = await admin.rpc("account_email_mark_sent", { target: id });
      if (error) throw error;
    },
    release: async (id, errorCode, giveUp) => {
      const { error } = await admin.rpc("account_email_release", {
        target: id,
        error_code: errorCode,
        give_up: giveUp,
      });
      if (error) throw error;
    },
    now: () => Date.now(),
    // Row ids and codes only: no addresses, names or household data in logs.
    log: (message, detail) => console.error(message, detail ?? ""),
  })
);
