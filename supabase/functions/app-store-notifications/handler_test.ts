import { assertEquals } from "@std/assert";
import {
  type ApplyOutcome,
  type AppStoreNotificationDeps,
  handleAppStoreNotification,
  type SubscriptionUpdate,
} from "./handler.ts";
import { household, type NotificationFixture, signedNotification, testRootDer } from "./testdata/sign.ts";
import { appleVerifier, NotConfigured } from "./verify.ts";

// The real verifier, trusting the test root.
const verify = appleVerifier({ roots: [testRootDer], onlineChecks: false, appAppleId: 1234567890 });

function fakeDeps(outcome: ApplyOutcome | Error = "applied", overrides: Partial<AppStoreNotificationDeps> = {}) {
  const applied: SubscriptionUpdate[] = [];
  const deps: AppStoreNotificationDeps = {
    verify,
    apply: (update) => {
      applied.push(update);
      return outcome instanceof Error ? Promise.reject(outcome) : Promise.resolve(outcome);
    },
    log: () => {},
    ...overrides,
  };
  return { deps, applied };
}

const post = (body: unknown) =>
  new Request("http://localhost/app-store-notifications", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

const notify = async (fixture: NotificationFixture) => post({ signedPayload: await signedNotification(fixture) });

Deno.test("a new trial updates the household it names", async () => {
  const { deps, applied } = fakeDeps();
  const uuid = crypto.randomUUID();
  const response = await handleAppStoreNotification(
    await notify({
      type: "SUBSCRIBED",
      subtype: "INITIAL_BUY",
      notificationUUID: uuid,
      transaction: { offerType: 1, offerDiscountType: "FREE_TRIAL", expiresDate: Date.UTC(2026, 11, 7) },
    }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "applied" });
  assertEquals(applied.length, 1);
  const { signedAt: _, ...update } = applied[0];
  assertEquals(update, {
    notificationUUID: uuid,
    household,
    notificationType: "SUBSCRIBED",
    subtype: "INITIAL_BUY",
    productId: "foon.family.monthly",
    originalTransactionId: "2000000000000001",
    environment: "Sandbox",
    status: "trial",
    expiresAt: new Date(Date.UTC(2026, 11, 7)),
    autoRenew: true,
  });
});

Deno.test("Apple's retry of one already handled is a 200, so it stops retrying", async () => {
  const { deps } = fakeDeps("duplicate");
  const response = await handleAppStoreNotification(await notify({ type: "DID_RENEW" }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "duplicate" });
});

Deno.test("a bad signature is a 400 and changes nothing", async () => {
  const { deps, applied } = fakeDeps();
  const other = appleVerifier({ roots: [], onlineChecks: false });
  const response = await handleAppStoreNotification(await notify({ type: "DID_RENEW" }), { ...deps, verify: other });
  assertEquals(response.status, 400);
  assertEquals(await response.json(), { error: "invalid_signature" });
  assertEquals(applied, []);
});

Deno.test("another app's notification is a 400", async () => {
  const { deps, applied } = fakeDeps();
  const response = await handleAppStoreNotification(
    await notify({ type: "DID_RENEW", bundleId: "com.example.other" }),
    deps,
  );
  assertEquals(response.status, 400);
  assertEquals(applied, []);
});

Deno.test("a body without a signed payload is a 400; anything but POST is a 405", async () => {
  const { deps } = fakeDeps();
  assertEquals((await handleAppStoreNotification(post("not json"), deps)).status, 400);
  assertEquals((await handleAppStoreNotification(post({ signedPayload: 42 }), deps)).status, 400);
  const get = new Request("http://localhost/app-store-notifications");
  assertEquals((await handleAppStoreNotification(get, deps)).status, 405);
});

Deno.test("Apple's test notification is answered and changes nothing", async () => {
  const { deps, applied } = fakeDeps();
  const response = await handleAppStoreNotification(await notify({ type: "TEST", transaction: null }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "test" });
  assertEquals(applied, []);
});

Deno.test("what isn't Foon's to act on is ignored with a 200", async () => {
  const cases: [NotificationFixture, string][] = [
    [{ type: "DID_RENEW", transaction: { productId: "com.example.coins" } }, "not_a_foon_product"],
    [{ type: "PRICE_INCREASE" }, "type_not_handled"],
    [{ type: "DID_RENEW", transaction: { appAccountToken: undefined } }, "no_household"],
    [{ type: "DID_RENEW", transaction: { appAccountToken: "not-a-uuid" } }, "no_household"],
    [{ type: "DID_RENEW", transaction: { originalTransactionId: undefined } }, "no_subscription"],
  ];
  for (const [fixture, reason] of cases) {
    const { deps, applied } = fakeDeps();
    const response = await handleAppStoreNotification(await notify(fixture), deps);
    assertEquals(response.status, 200, reason);
    assertEquals(await response.json(), { result: "ignored", reason });
    assertEquals(applied, [], reason);
  }
});

Deno.test("a token that isn't a household is ignored", async () => {
  const { deps } = fakeDeps("no_household");
  const response = await handleAppStoreNotification(await notify({ type: "DID_RENEW" }), deps);
  assertEquals(await response.json(), { result: "ignored", reason: "no_household" });
});

Deno.test("each type reaches the database with its status", async () => {
  const cases: [NotificationFixture, string | null][] = [
    [{ type: "DID_RENEW" }, "active"],
    [{ type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD" }, "lapsed"],
    [{ type: "GRACE_PERIOD_EXPIRED" }, "lapsed"],
    [{ type: "EXPIRED", subtype: "VOLUNTARY" }, "cancelled"],
    [{ type: "REFUND" }, "cancelled"],
    [{ type: "REVOKE" }, "cancelled"],
    [{ type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED" }, null],
  ];
  for (const [fixture, status] of cases) {
    const { deps, applied } = fakeDeps();
    const response = await handleAppStoreNotification(await notify(fixture), deps);
    assertEquals(response.status, 200, fixture.type);
    assertEquals(applied[0]?.status, status, fixture.type);
  }
});

Deno.test("a database failure is a 500, so Apple tries again", async () => {
  const { deps } = fakeDeps(new Error("connection reset"));
  const response = await handleAppStoreNotification(await notify({ type: "DID_RENEW" }), deps);
  assertEquals(response.status, 500);
});

Deno.test("production before APPLE_APP_ID is set is a 500, not trusted", async () => {
  const { deps, applied } = fakeDeps();
  const response = await handleAppStoreNotification(await notify({ type: "DID_RENEW", environment: "Production" }), {
    ...deps,
    verify: () => Promise.reject(new NotConfigured("APPLE_APP_ID is not set")),
  });
  assertEquals(response.status, 500);
  assertEquals(applied, []);
});
