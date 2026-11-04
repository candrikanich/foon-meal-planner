// Signs fixture JWS the way the App Store does: ES256, with the leaf, intermediate and root in the x5c header.
import { base64url } from "../../_shared/es256.ts";
import { testIntermediatePem, testLeafKeyPem, testLeafPem, testRootPem } from "./pki.ts";

export const derOf = (pem: string): Uint8Array<ArrayBuffer> =>
  Uint8Array.from(atob(pem.replace(/-----(BEGIN|END) [A-Z ]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));

const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

export const testRootDer = derOf(testRootPem);

const leafKey = crypto.subtle.importKey("pkcs8", derOf(testLeafKeyPem), { name: "ECDSA", namedCurve: "P-256" }, false, [
  "sign",
]);

export async function signJWS(payload: unknown): Promise<string> {
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const header = {
    alg: "ES256",
    x5c: [testLeafPem, testIntermediatePem, testRootPem].map((pem) => base64(derOf(pem))),
  };
  const signingInput = `${encode(header)}.${encode(payload)}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await leafKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

export const household = "3f1c9a2e-8b4d-4e6f-9a1b-2c3d4e5f6a7b";

export interface NotificationFixture {
  type: string;
  subtype?: string;
  environment?: "Sandbox" | "Production";
  bundleId?: string;
  transaction?: Record<string, unknown> | null;
  renewal?: Record<string, unknown>;
  notificationUUID?: string;
}

// A signed notification with signed transaction and renewal info, as Apple sends it.
export async function signedNotification(fixture: NotificationFixture): Promise<string> {
  const environment = fixture.environment ?? "Sandbox";
  const bundleId = fixture.bundleId ?? "com.andrikanich.foon";
  const now = Date.now();
  const transaction = fixture.transaction === null ? undefined : await signJWS({
    bundleId,
    environment,
    signedDate: now,
    productId: "foon.family.monthly",
    originalTransactionId: "2000000000000001",
    transactionId: "2000000000000002",
    appAccountToken: household,
    expiresDate: now + 30 * 86_400_000,
    type: "Auto-Renewable Subscription",
    ...fixture.transaction,
  });
  const renewal = fixture.transaction === null ? undefined : await signJWS({
    environment,
    signedDate: now,
    productId: "foon.family.monthly",
    originalTransactionId: "2000000000000001",
    autoRenewStatus: 1,
    ...fixture.renewal,
  });
  return signJWS({
    notificationType: fixture.type,
    subtype: fixture.subtype,
    notificationUUID: fixture.notificationUUID ?? crypto.randomUUID(),
    version: "2.0",
    signedDate: now,
    data: {
      bundleId,
      appAppleId: environment === "Production" ? 1234567890 : undefined,
      environment,
      signedTransactionInfo: transaction,
      signedRenewalInfo: renewal,
    },
  });
}
