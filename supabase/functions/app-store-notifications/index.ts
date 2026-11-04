// Apple calls it with no JWT, so it skips Supabase's JWT check (config.toml); the signature on the payload is the check.
// Needs the service role, and APPLE_APP_ID (the app's numeric App Store id, not a secret) for production notifications.
// Verification needs no secret: Apple Root CA - G3 ships with the function.
import { createClient } from "@supabase/supabase-js";
import { appleRootCAG3Base64 } from "./apple_root_ca_g3.ts";
import { handleAppStoreNotification } from "./handler.ts";
import { appleVerifier } from "./verify.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const admin = createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});

const appAppleId = Number(Deno.env.get("APPLE_APP_ID"));
const verify = appleVerifier({
  roots: [Uint8Array.from(atob(appleRootCAG3Base64), (c) => c.charCodeAt(0))],
  onlineChecks: true,
  appAppleId: Number.isInteger(appAppleId) && appAppleId > 0 ? appAppleId : undefined,
});

Deno.serve((req) =>
  handleAppStoreNotification(req, {
    verify,
    apply: async (update) => {
      const { data, error } = await admin.rpc("apply_subscription_notification", {
        notification_uuid: update.notificationUUID,
        target_household: update.household,
        notification_type: update.notificationType,
        subtype: update.subtype,
        product_id: update.productId,
        original_transaction_id: update.originalTransactionId,
        environment: update.environment,
        signed_at: update.signedAt.toISOString(),
        new_status: update.status,
        expires_at: update.expiresAt?.toISOString() ?? null,
        period_ends_at: update.periodEndsAt?.toISOString() ?? null,
        auto_renew: update.autoRenew,
      });
      if (error) throw error;
      return data;
    },
    log: (message, error) => console.error(message, error instanceof Error ? error.message : error ?? ""),
  })
);
