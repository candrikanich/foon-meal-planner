// Verifies Apple's signed notification and the transaction and renewal info inside it with Apple's own library
// (@apple/app-store-server-library): the x5c chain must lead to a trusted root, the leaf and intermediate must carry
// Apple's marker extensions, and the bundle id and environment must match. Production trusts only Apple Root CA - G3
// with online (OCSP and current-date) checks; tests pass their own root and turn the online checks off.
import { Environment, SignedDataVerifier, VerificationException } from "@apple/app-store-server-library";
import { Buffer } from "node:buffer";
import type { RenewalInfo, Transaction } from "./entitlement.ts";

export const bundleId = "com.andrikanich.foon";

export interface VerifiedNotification {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  signedDate: Date;
  environment: "Sandbox" | "Production";
  // Absent for TEST and for summary notifications.
  transaction?: Transaction;
  renewal?: RenewalInfo;
}

// The payload isn't Apple's: a bad signature, chain, bundle id, or environment. Apple gets a 4xx.
export class InvalidNotification extends Error {}

// Apple sent something we can't check yet (production without APPLE_APP_ID). Apple gets a 5xx and retries.
export class NotConfigured extends Error {}

export interface VerifierOptions {
  // DER certificates.
  roots: Uint8Array[];
  onlineChecks: boolean;
  // The app's numeric App Store id; the library requires it to check production notifications.
  appAppleId?: number;
}

export type Verify = (signedPayload: string) => Promise<VerifiedNotification>;

// Only to pick which environment's verifier checks it; that verifier then rejects a payload whose environment lies.
function claimedEnvironment(signedPayload: string): unknown {
  try {
    const body = signedPayload.split(".")[1] ?? "";
    const json = atob(body.replaceAll("-", "+").replaceAll("_", "/"));
    return JSON.parse(json)?.data?.environment;
  } catch {
    return undefined;
  }
}

export function appleVerifier({ roots, onlineChecks, appAppleId }: VerifierOptions): Verify {
  const certificates = roots.map((root) => Buffer.from(root));
  const sandbox = new SignedDataVerifier(certificates, onlineChecks, Environment.SANDBOX, bundleId);
  const production = appAppleId === undefined
    ? null
    : new SignedDataVerifier(certificates, onlineChecks, Environment.PRODUCTION, bundleId, appAppleId);

  return async (signedPayload) => {
    const environment = claimedEnvironment(signedPayload);
    if (environment !== "Sandbox" && environment !== "Production") throw new InvalidNotification("unknown environment");
    const verifier = environment === "Production" ? production : sandbox;
    if (!verifier) throw new NotConfigured("APPLE_APP_ID is not set");

    try {
      const notification = await verifier.verifyAndDecodeNotification(signedPayload);
      const data = notification.data;
      const transaction = data?.signedTransactionInfo
        ? await verifier.verifyAndDecodeTransaction(data.signedTransactionInfo)
        : undefined;
      const renewal = data?.signedRenewalInfo
        ? await verifier.verifyAndDecodeRenewalInfo(data.signedRenewalInfo)
        : undefined;
      if (!notification.notificationType || !notification.notificationUUID || notification.signedDate === undefined) {
        throw new InvalidNotification("missing notification fields");
      }
      return {
        notificationType: notification.notificationType,
        subtype: notification.subtype,
        notificationUUID: notification.notificationUUID,
        signedDate: new Date(notification.signedDate),
        environment,
        transaction: transaction as Transaction | undefined,
        renewal: renewal as RenewalInfo | undefined,
      };
    } catch (error) {
      if (error instanceof VerificationException) throw new InvalidNotification(`verification status ${error.status}`);
      throw error;
    }
  };
}
