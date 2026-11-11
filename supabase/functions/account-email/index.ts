// Sends Foon's account emails (#48). Three doors, none behind the gateway's JWT check (config.toml):
//   POST (x-account-email-secret)            pg_cron's run: sends what's queued (handler.ts)
//   GET/POST ?unsubscribe=<signed>           an opt-in email's unsubscribe link and one-click (unsubscribe.ts)
//   POST ?founding=preview|send              the "Founding update" Action (x-founding-updates-secret; founding.ts)
// Needs the service role. RESEND_API_KEY and ACCOUNT_EMAIL_FROM turn email on; ACCOUNT_EMAIL_SITE_URL overrides
// https://getfoon.com for links; EMAIL_POSTAL_ADDRESS (lines split by ";") is required for founding updates;
// FOUNDING_UPDATES_SECRET and FOUNDING_UPDATES_PREVIEW_TO are the Action's. Nothing is claimed until
// app_config.account_email_enabled is on. docs/account-email.md has the setup.
import { createClient } from "@supabase/supabase-js";
import { resendConfigFromEnv, sendEmail } from "../_shared/resend.ts";
import { DEFAULT_SITE_URL } from "./email.ts";
import { handleFoundingUpdate } from "./founding.ts";
import { type ClaimedEmail, handleAccountEmail } from "./handler.ts";
import { type FoundingUpdate, parsePostalAddress } from "./opt_in_email.ts";
import { handleUnsubscribe, unsubscribeLinks, unsubscribeOrigins } from "./unsubscribe.ts";

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
const resend = resendConfigFromEnv((key) => Deno.env.get(key), "ACCOUNT_EMAIL_FROM");
const send = resend ? (email: Parameters<typeof sendEmail>[1]) => sendEmail(resend, email) : null;
const siteUrl = Deno.env.get("ACCOUNT_EMAIL_SITE_URL") || DEFAULT_SITE_URL;
const postalAddress = parsePostalAddress(Deno.env.get("EMAIL_POSTAL_ADDRESS"));
const links = unsubscribeLinks(serviceKey, `${supabaseUrl}/functions/v1/account-email`);
// Row ids and codes only: no addresses, names or household data in logs.
const log = (message: string, detail?: unknown) => console.error(message, detail ?? "");

async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await admin.rpc(name, args);
  if (error) throw error;
  return data as T;
}

Deno.serve((req) => {
  const url = new URL(req.url);
  const unsubscribe = url.searchParams.get("unsubscribe");
  if (unsubscribe !== null) {
    return handleUnsubscribe(req, unsubscribe, {
      allowedOrigins: unsubscribeOrigins(siteUrl),
      siteUrl,
      sign: links.sign,
      unsubscribe: (userId, kind) => rpc("email_unsubscribe", { account: userId, email_kind: kind }),
      log,
    });
  }

  if (url.searchParams.has("founding")) {
    return handleFoundingUpdate(req, {
      secret: Deno.env.get("FOUNDING_UPDATES_SECRET"),
      previewTo: Deno.env.get("FOUNDING_UPDATES_PREVIEW_TO"),
      postalAddress,
      send,
      unsubscribeUrl: links.url,
      audience: () => rpc<number>("founding_update_audience"),
      queue: async (subject, body) => {
        const { data, error } = await admin.rpc("queue_founding_update", {
          update_subject: subject,
          update_body: body,
        });
        if (error?.code === "55000") return "email_off";
        if (error) throw error;
        return { updateId: data.update_id, queued: data.queued, repeat: data.repeat };
      },
      log,
    });
  }

  return handleAccountEmail(req, {
    cronSecret: Deno.env.get("ACCOUNT_EMAIL_CRON_SECRET"),
    siteUrl,
    send,
    claim: (limit) => rpc<ClaimedEmail[]>("claim_account_emails", { batch_size: limit }),
    markSent: (id) => rpc("account_email_mark_sent", { target: id }),
    release: (id, errorCode, giveUp) =>
      rpc("account_email_release", { target: id, error_code: errorCode, give_up: giveUp }),
    now: () => Date.now(),
    log,
    weeklyPlan: (planId) => rpc("account_email_weekly_plan", { target_plan: planId }),
    foundingUpdate: (updateId) => rpc<FoundingUpdate | null>("account_email_founding_update", { target: updateId }),
    unsubscribeUrl: links.url,
    postalAddress,
  });
});
