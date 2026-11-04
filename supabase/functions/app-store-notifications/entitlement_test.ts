import { assertEquals } from "@std/assert";
import { entitlementChange, type Transaction } from "./entitlement.ts";

const expires = Date.UTC(2026, 11, 7);
const transaction: Transaction = { productId: "foon.family.monthly", expiresDate: expires };
const renewing = { autoRenewStatus: 1 };

Deno.test("a new subscription with the free trial is a trial; without it, active", () => {
  const trial = { ...transaction, offerType: 1, offerDiscountType: "FREE_TRIAL" };
  assertEquals(entitlementChange("SUBSCRIBED", "INITIAL_BUY", trial, renewing), {
    status: "trial",
    expiresAt: new Date(expires),
    autoRenew: true,
  });
  assertEquals(entitlementChange("SUBSCRIBED", "RESUBSCRIBE", transaction, renewing)?.status, "active");
  const payUpFront = { ...transaction, offerType: 1, offerDiscountType: "PAY_UP_FRONT" };
  assertEquals(entitlementChange("SUBSCRIBED", "INITIAL_BUY", payUpFront, renewing)?.status, "active");
});

Deno.test("a renewal is active to the new expiry", () => {
  assertEquals(entitlementChange("DID_RENEW", undefined, transaction, renewing), {
    status: "active",
    expiresAt: new Date(expires),
    autoRenew: true,
  });
});

Deno.test("a failed renewal lapses, entitled to the end of a grace period", () => {
  const graceEnds = expires + 16 * 86_400_000;
  assertEquals(
    entitlementChange("DID_FAIL_TO_RENEW", "GRACE_PERIOD", transaction, {
      autoRenewStatus: 1,
      gracePeriodExpiresDate: graceEnds,
    })
      ?.expiresAt,
    new Date(graceEnds),
  );
  assertEquals(entitlementChange("DID_FAIL_TO_RENEW", undefined, transaction, renewing), {
    status: "lapsed",
    expiresAt: new Date(expires),
    autoRenew: true,
  });
  assertEquals(entitlementChange("GRACE_PERIOD_EXPIRED", undefined, transaction, renewing)?.status, "lapsed");
});

Deno.test("expiring is cancelled, unless Apple gave up retrying a payment", () => {
  assertEquals(entitlementChange("EXPIRED", "VOLUNTARY", transaction, undefined), {
    status: "cancelled",
    expiresAt: new Date(expires),
    autoRenew: false,
  });
  assertEquals(entitlementChange("EXPIRED", "BILLING_RETRY", transaction, undefined)?.status, "lapsed");
  assertEquals(entitlementChange("EXPIRED", "PRODUCT_NOT_FOR_SALE", transaction, undefined)?.status, "cancelled");
});

Deno.test("a refund or revocation ends it when it was revoked", () => {
  const revoked = Date.UTC(2026, 10, 20);
  for (const type of ["REFUND", "REVOKE"]) {
    assertEquals(entitlementChange(type, undefined, { ...transaction, revocationDate: revoked }, undefined), {
      status: "cancelled",
      expiresAt: new Date(revoked),
      autoRenew: null,
    });
  }
});

Deno.test("turning auto-renew off or on keeps the status until the period ends", () => {
  assertEquals(
    entitlementChange("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED", transaction, { autoRenewStatus: 0 }),
    {
      status: null,
      expiresAt: new Date(expires),
      autoRenew: false,
    },
  );
  assertEquals(
    entitlementChange("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED", transaction, undefined)?.autoRenew,
    true,
  );
});

Deno.test("other notifications don't change entitlement", () => {
  for (const type of ["TEST", "PRICE_INCREASE", "OFFER_REDEEMED", "DID_CHANGE_RENEWAL_PREF", "CONSUMPTION_REQUEST"]) {
    assertEquals(entitlementChange(type, undefined, transaction, renewing), null);
  }
});

Deno.test("a reversed refund gives access back; an upgrade moves to the new product at once", () => {
  assertEquals(entitlementChange("REFUND_REVERSED", undefined, transaction, renewing)?.status, "active");
  assertEquals(entitlementChange("DID_CHANGE_RENEWAL_PREF", "UPGRADE", transaction, renewing), {
    status: "active",
    expiresAt: new Date(expires),
    autoRenew: true,
  });
  assertEquals(entitlementChange("DID_CHANGE_RENEWAL_PREF", "DOWNGRADE", transaction, renewing), null);
});

Deno.test("an extended renewal only moves the expiry", () => {
  assertEquals(entitlementChange("RENEWAL_EXTENDED", undefined, transaction, renewing), {
    status: null,
    expiresAt: new Date(expires),
    autoRenew: true,
  });
});
