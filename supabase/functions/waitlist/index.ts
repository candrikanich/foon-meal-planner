// Browsers and mail clients call it with no Supabase JWT, so it skips the JWT check (config.toml); the rules are in
// handler.ts. Needs the service role. RESEND_API_KEY and WAITLIST_FROM turn the confirmation email on; without them a
// signup is stored and the log says email is off. WAITLIST_SITE_URL overrides https://getfoon.com (e.g. a preview).
import { createClient } from "@supabase/supabase-js";
import { newToken, sha256, signer } from "./crypto.ts";
import { resendConfigFromEnv, sendViaResend } from "./email.ts";
import { type ConfirmOutcome, handleWaitlist, type JoinOutcome } from "./handler.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const supabaseUrl = required("SUPABASE_URL");
const serviceKey = required("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
const resend = resendConfigFromEnv((key) => Deno.env.get(key));
const sign = signer(serviceKey);

Deno.serve((req) =>
  handleWaitlist(req, {
    allowedOrigins: [
      "https://getfoon.com",
      "https://www.getfoon.com",
      "http://localhost:3000",
      "http://localhost:3001",
      "http://127.0.0.1:3000",
    ],
    siteUrl: Deno.env.get("WAITLIST_SITE_URL") ?? "https://getfoon.com",
    functionUrl: `${supabaseUrl}/functions/v1/waitlist`,
    join: async ({ email, firstName, tokenHash, ipHash }) => {
      const { data, error } = await admin.rpc("waitlist_join", {
        p_email: email,
        p_first_name: firstName,
        p_token_hash: tokenHash,
        p_ip_hash: ipHash,
      });
      if (error) throw error;
      return data as JoinOutcome;
    },
    confirm: async (tokenHash) => {
      const { data, error } = await admin.rpc("waitlist_confirm", { p_token_hash: tokenHash });
      if (error) throw error;
      return data as ConfirmOutcome;
    },
    unsubscribe: async (id) => {
      const { data, error } = await admin.rpc("waitlist_unsubscribe", { p_id: id });
      if (error) throw error;
      return data as boolean;
    },
    idFor: async (email) => {
      const { data, error } = await admin.rpc("waitlist_id_for", { p_email: email });
      if (error) throw error;
      return data as string | null;
    },
    newToken,
    sha256,
    sign,
    sendConfirmation: async (message) => {
      if (!resend) return "off";
      await sendViaResend(resend, message.to, message);
      return "sent";
    },
    log: (message, error) => console.error(message, error instanceof Error ? error.message : error ?? ""),
  })
);
