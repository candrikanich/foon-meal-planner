// Sends what's due in push_outbox through APNs (#40 part 2). pg_cron calls it through pg_net with the PUSH_CRON_SECRET
// header, so it skips Supabase's JWT check (config.toml). Needs the service role and the Apple key: APPLE_TEAM_ID,
// APPLE_KEY_ID, APPLE_PRIVATE_KEY; on staging also APNS_TOPIC=com.andrikanich.foon.qa (Foon QA). Unset, it's
// Foon's com.andrikanich.foon.
import { createClient } from "@supabase/supabase-js";
import { apnsConfigFromEnv, apnsTopicFromEnv, cachedProviderToken, deliver } from "./apns.ts";
import { handleSendPush, type OutboxRow } from "./handler.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const admin = createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const apns = apnsConfigFromEnv((key) => Deno.env.get(key));
const topic = apnsTopicFromEnv((key) => Deno.env.get(key));

const tokenStore = {
  load: async (keyId: string) => {
    const { data, error } = await admin.from("push_provider_tokens").select("token, issued_at").eq("key_id", keyId)
      .maybeSingle();
    if (error) throw error;
    return data ? { token: data.token as string, issuedAt: new Date(data.issued_at as string) } : null;
  },
  save: async (keyId: string, token: string, issuedAt: Date) => {
    const { error } = await admin.from("push_provider_tokens")
      .upsert({ key_id: keyId, token, issued_at: issuedAt.toISOString() });
    if (error) throw error;
  },
};

Deno.serve((req) =>
  handleSendPush(req, {
    cronSecret: Deno.env.get("PUSH_CRON_SECRET"),
    providerToken: apns ? () => cachedProviderToken(apns, tokenStore) : null,
    claim: async (limit) => {
      const { data, error } = await admin.rpc("claim_push_outbox", { batch_size: limit });
      if (error) throw error;
      return data as OutboxRow[];
    },
    deliver: (device, payload, jwt) =>
      deliver(device, payload, jwt, topic, fetch, new Date(), (refusal) => console.error(`apns refused: ${refusal}`)),
    forgetDevices: async (tokens) => {
      const { error } = await admin.rpc("forget_push_devices", { tokens });
      if (error) throw error;
    },
    complete: async (id, outcome) => {
      const { error } = await admin.rpc("complete_push_outbox", { target: id, outcome });
      if (error) throw error;
    },
    // Ids and status codes only: no tokens, names, or household data in logs.
    log: (message, error) => console.error(message, error instanceof Error ? error.message : error),
  })
);
