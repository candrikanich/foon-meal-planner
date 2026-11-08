// Browsers and mail clients call it with no Supabase JWT, so it skips the JWT check (config.toml); the rules are in
// handler.ts. Needs the service role. RESEND_API_KEY and WAITLIST_FROM turn the confirmation email on; without them a
// signup is stored and the log says email is off. WAITLIST_SITE_URL overrides https://getfoon.com (e.g. a preview).
import { createClient } from "@supabase/supabase-js";
import { resendConfigFromEnv } from "../_shared/resend.ts";
import { newToken, sha256 } from "../_shared/token.ts";
import { signer } from "./crypto.ts";
import { sendViaResend } from "./email.ts";
import { type ConfirmOutcome, handleWaitlist } from "./handler.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const supabaseUrl = required("SUPABASE_URL");
const serviceKey = required("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(supabaseUrl, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const resend = resendConfigFromEnv((key) => Deno.env.get(key), "WAITLIST_FROM");
const sign = signer(serviceKey);

// Supabase's runtime global: keeps the function alive for work started after the response.
declare const EdgeRuntime: { waitUntil(work: Promise<unknown>): void };

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
    join: async ({ email, firstName, ipHash }) => {
      const { data, error } = await admin.rpc("waitlist_join", {
        p_email: email,
        p_first_name: firstName,
        p_ip_hash: ipHash,
      });
      if (error) throw error;
      return data.outcome === "send"
        ? {
          outcome: "send",
          signupId: data.signup_id,
          attemptId: data.attempt_id,
        }
        : { outcome: data.outcome };
    },
    releaseSend: async ({ signupId, attemptId }) => {
      const { error } = await admin.rpc("waitlist_release_send", {
        p_signup_id: signupId,
        p_attempt_id: attemptId,
      });
      if (error) throw error;
    },
    markSent: async ({ signupId, attemptId, tokenHash, firstName }) => {
      const { error } = await admin.rpc("waitlist_mark_sent", {
        p_signup_id: signupId,
        p_attempt_id: attemptId,
        p_token_hash: tokenHash,
        p_first_name: firstName,
      });
      if (error) throw error;
    },
    confirm: async (tokenHash) => {
      const { data, error } = await admin.rpc("waitlist_confirm", {
        p_token_hash: tokenHash,
      });
      if (error) throw error;
      return data as ConfirmOutcome;
    },
    unsubscribe: async (id) => {
      const { error } = await admin.rpc("waitlist_unsubscribe", { p_id: id });
      if (error) throw error;
    },
    newToken,
    sha256,
    sign,
    sendConfirmation: async (message) => {
      if (!resend) return "off";
      await sendViaResend(resend, message.to, message);
      return "sent";
    },
    defer: (work) => EdgeRuntime.waitUntil(work),
    log: (message, error) =>
      console.error(
        message,
        error instanceof Error ? error.message : error ?? "",
      ),
  })
);
