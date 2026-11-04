// What an App Store notification does to the household's entitlement: a pure mapping from Apple's notification type,
// subtype, and the decoded transaction and renewal info to the status and expiry the database stores.

export type SubscriptionStatus = "trial" | "active" | "lapsed" | "cancelled";

// The fields Foon reads from Apple's JWSTransactionDecodedPayload (dates are milliseconds since 1970).
export interface Transaction {
  bundleId?: string;
  productId?: string;
  originalTransactionId?: string;
  appAccountToken?: string;
  expiresDate?: number;
  revocationDate?: number;
  // 1 is an introductory offer; with offerDiscountType FREE_TRIAL it's the 30-day free trial.
  offerType?: number;
  offerDiscountType?: string;
}

// The fields Foon reads from Apple's JWSRenewalInfoDecodedPayload.
export interface RenewalInfo {
  autoRenewStatus?: number;
  gracePeriodExpiresDate?: number;
}

export interface EntitlementChange {
  // Null: the status stays as it is (auto-renew turned on or off changes nothing until the period ends).
  status: SubscriptionStatus | null;
  expiresAt: Date | null;
  autoRenew: boolean | null;
}

const date = (ms: number | undefined) => (ms === undefined ? null : new Date(ms));

function startedStatus(transaction: Transaction): SubscriptionStatus {
  const freeTrial = transaction.offerType === 1 && (transaction.offerDiscountType ?? "FREE_TRIAL") === "FREE_TRIAL";
  return freeTrial ? "trial" : "active";
}

// Null for a notification that doesn't change entitlement (TEST, price increases, offers redeemed, and so on).
export function entitlementChange(
  type: string,
  subtype: string | undefined,
  transaction: Transaction,
  renewal: RenewalInfo | undefined,
): EntitlementChange | null {
  const expires = date(transaction.expiresDate);
  const autoRenew = renewal?.autoRenewStatus === undefined ? null : renewal.autoRenewStatus === 1;
  switch (type) {
    case "SUBSCRIBED":
      return { status: startedStatus(transaction), expiresAt: expires, autoRenew };
    case "DID_RENEW":
    // Apple reversed a refund: access comes back.
    case "REFUND_REVERSED":
      return { status: "active", expiresAt: expires, autoRenew };
    // An upgrade (monthly to annual) takes effect at once with the new product and expiry; a downgrade or crossgrade
    // waits for the renewal, which says so itself.
    case "DID_CHANGE_RENEWAL_PREF":
      return subtype === "UPGRADE" ? { status: "active", expiresAt: expires, autoRenew } : null;
    // Apple extended the period (a service outage, say): only the expiry moves.
    case "RENEWAL_EXTENDED":
      return { status: null, expiresAt: expires, autoRenew };
    case "DID_FAIL_TO_RENEW": {
      // In a grace period the family keeps the app until it ends; without one, access ends with the period.
      const graceEnds = subtype === "GRACE_PERIOD" ? date(renewal?.gracePeriodExpiresDate) : null;
      return { status: "lapsed", expiresAt: graceEnds ?? expires, autoRenew };
    }
    case "GRACE_PERIOD_EXPIRED":
      return { status: "lapsed", expiresAt: expires, autoRenew };
    case "EXPIRED":
      // Apple stopped retrying a failed payment: lapsed. Turned off, or no longer for sale: cancelled.
      return { status: subtype === "BILLING_RETRY" ? "lapsed" : "cancelled", expiresAt: expires, autoRenew: false };
    case "REFUND":
    case "REVOKE":
      return { status: "cancelled", expiresAt: date(transaction.revocationDate) ?? expires, autoRenew };
    case "DID_CHANGE_RENEWAL_STATUS":
      return {
        status: null,
        expiresAt: expires,
        autoRenew: subtype === "AUTO_RENEW_ENABLED" ? true : subtype === "AUTO_RENEW_DISABLED" ? false : autoRenew,
      };
    default:
      return null;
  }
}
