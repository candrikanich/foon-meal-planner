// app-store-notifications: Apple's App Store Server Notifications V2 POST {signedPayload} here. A verified notification
// for a Foon product finds its household by appAccountToken (the household's id, set by the app at purchase) and updates
// the household's entitlement. Apple retries anything but a 200, so everything handled or deliberately ignored is a 200;
// a payload that isn't Apple's is a 400, and a failure on our side is a 500 so Apple tries again.
import { entitlementChange, type SubscriptionStatus } from "./entitlement.ts";
import { isFoonProduct } from "./products.ts";
import { InvalidNotification, NotConfigured, type Verify } from "./verify.ts";

export interface SubscriptionUpdate {
  notificationUUID: string;
  household: string;
  notificationType: string;
  subtype: string | null;
  productId: string;
  originalTransactionId: string;
  environment: "Sandbox" | "Production";
  signedAt: Date;
  status: SubscriptionStatus | null;
  expiresAt: Date | null;
  // The transaction's own period end: a refund of a period before the current one doesn't cancel it.
  periodEndsAt: Date | null;
  autoRenew: boolean | null;
}

// What apply_subscription_notification returns.
export type ApplyOutcome = "applied" | "stale" | "older_period" | "duplicate" | "no_household";

export interface AppStoreNotificationDeps {
  verify: Verify;
  apply(update: SubscriptionUpdate): Promise<ApplyOutcome>;
  // Types, outcomes and ids only: no tokens or payloads in logs.
  log(message: string, error?: unknown): void;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const ignored = (reason: string) => json(200, { result: "ignored", reason });

async function signedPayloadOf(req: Request): Promise<string | null> {
  try {
    const body = await req.json();
    return typeof body?.signedPayload === "string" && body.signedPayload.length > 0 ? body.signedPayload : null;
  } catch {
    return null;
  }
}

export async function handleAppStoreNotification(req: Request, deps: AppStoreNotificationDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const signedPayload = await signedPayloadOf(req);
  if (!signedPayload) return json(400, { error: "bad_request" });

  let notification;
  try {
    notification = await deps.verify(signedPayload);
  } catch (error) {
    if (error instanceof InvalidNotification) {
      deps.log("rejected notification", error);
      return json(400, { error: "invalid_signature" });
    }
    deps.log(error instanceof NotConfigured ? "not configured" : "verification failed", error);
    return json(500, { error: "not_verified" });
  }

  const { notificationType, subtype, transaction, renewal } = notification;
  if (notificationType === "TEST") return json(200, { result: "test" });
  if (!transaction) return ignored("no_transaction");
  if (!isFoonProduct(transaction.productId)) return ignored("not_a_foon_product");
  const change = entitlementChange(notificationType, subtype, transaction, renewal);
  if (!change) return ignored("type_not_handled");
  if (!transaction.originalTransactionId) return ignored("no_subscription");
  const household = transaction.appAccountToken;
  if (!household || !uuidPattern.test(household)) {
    deps.log(`no household token on ${notificationType} ${notification.notificationUUID}`);
    return ignored("no_household");
  }

  try {
    const outcome = await deps.apply({
      notificationUUID: notification.notificationUUID,
      household: household.toLowerCase(),
      notificationType,
      subtype: subtype ?? null,
      productId: transaction.productId,
      originalTransactionId: transaction.originalTransactionId,
      environment: notification.environment,
      signedAt: notification.signedDate,
      periodEndsAt: transaction.expiresDate === undefined ? null : new Date(transaction.expiresDate),
      ...change,
    });
    if (outcome === "no_household") {
      deps.log(`unknown household on ${notificationType} ${notification.notificationUUID}`);
      return ignored("no_household");
    }
    return json(200, { result: outcome });
  } catch (error) {
    deps.log("apply failed", error);
    return json(500, { error: "apply_failed" });
  }
}
