import { assertEquals, assertRejects } from "@std/assert";
import { appleRootCAG3Base64 } from "./apple_root_ca_g3.ts";
import { household, signedNotification, signJWS, testRootDer } from "./testdata/sign.ts";
import { testPki } from "./testdata/pki.ts";
import { appleVerifier, InvalidNotification, NotConfigured } from "./verify.ts";

const appleRoot = Uint8Array.from(atob(appleRootCAG3Base64), (c) => c.charCodeAt(0));
const verify = appleVerifier({ roots: [testRootDer], onlineChecks: false, appAppleId: 1234567890 });

Deno.test("the bundled root is Apple Root CA - G3", async () => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", appleRoot));
  const fingerprint = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join(":").toUpperCase();
  assertEquals(
    fingerprint,
    "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79",
  );
});

Deno.test("decodes a notification signed under the trusted root, with its transaction and renewal info", async () => {
  const verified = await verify(await signedNotification({ type: "SUBSCRIBED", subtype: "INITIAL_BUY" }));
  assertEquals(verified.notificationType, "SUBSCRIBED");
  assertEquals(verified.subtype, "INITIAL_BUY");
  assertEquals(verified.environment, "Sandbox");
  assertEquals(verified.transaction?.appAccountToken, household);
  assertEquals(verified.transaction?.productId, "foon.family.monthly");
  assertEquals(verified.renewal?.autoRenewStatus, 1);
});

Deno.test("checks production notifications with the app's id", async () => {
  const verified = await verify(await signedNotification({ type: "DID_RENEW", environment: "Production" }));
  assertEquals(verified.environment, "Production");
});

Deno.test("production needs the app's id, so it fails as not configured rather than trusting it", async () => {
  const unconfigured = appleVerifier({ roots: [testRootDer], onlineChecks: false });
  const notification = await signedNotification({ type: "DID_RENEW", environment: "Production" });
  await assertRejects(() => unconfigured(notification), NotConfigured);
});

Deno.test("Apple's root doesn't trust the test chain", async () => {
  const production = appleVerifier({ roots: [appleRoot], onlineChecks: false, appAppleId: 1234567890 });
  await assertRejects(async () => production(await signedNotification({ type: "SUBSCRIBED" })), InvalidNotification);
});

Deno.test("another root doesn't verify it", async () => {
  const other = appleVerifier({ roots: [testPki.intermediateDer], onlineChecks: false });
  await assertRejects(async () => other(await signedNotification({ type: "SUBSCRIBED" })), InvalidNotification);
});

Deno.test("a changed payload fails its signature", async () => {
  const [header, body, signature] = (await signedNotification({ type: "SUBSCRIBED" })).split(".");
  const claims = JSON.parse(atob(body.replaceAll("-", "+").replaceAll("_", "/")));
  const forged = btoa(JSON.stringify({ ...claims, notificationType: "DID_RENEW" }))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  await assertRejects(() => verify(`${header}.${forged}.${signature}`), InvalidNotification);
});

Deno.test("another app's notification is refused", async () => {
  await assertRejects(
    async () => verify(await signedNotification({ type: "SUBSCRIBED", bundleId: "com.example.other" })),
    InvalidNotification,
  );
});

Deno.test("a transaction from the other environment is refused", async () => {
  const notification = await signJWS({
    notificationType: "DID_RENEW",
    notificationUUID: crypto.randomUUID(),
    signedDate: Date.now(),
    data: {
      bundleId: "com.andrikanich.foon",
      environment: "Sandbox",
      signedTransactionInfo: await signJWS({
        bundleId: "com.andrikanich.foon",
        environment: "Production",
        signedDate: Date.now(),
        productId: "foon.family.monthly",
      }),
    },
  });
  await assertRejects(() => verify(notification), InvalidNotification);
});

Deno.test("a summary notification finds its environment in the summary", async () => {
  const notification = await signJWS({
    notificationType: "RENEWAL_EXTENSION",
    subtype: "SUMMARY",
    notificationUUID: crypto.randomUUID(),
    version: "2.0",
    signedDate: Date.now(),
    summary: {
      requestIdentifier: crypto.randomUUID(),
      environment: "Sandbox",
      bundleId: "com.andrikanich.foon",
      productId: "foon.family.monthly",
      storefrontCountryCodes: ["USA"],
      succeededCount: 1,
      failedCount: 0,
    },
  });
  const verified = await verify(notification);
  assertEquals(verified.environment, "Sandbox");
  assertEquals(verified.transaction, undefined);
});

Deno.test("something that isn't a JWS is refused", async () => {
  await assertRejects(() => verify("not.a.jws"), InvalidNotification);
});
