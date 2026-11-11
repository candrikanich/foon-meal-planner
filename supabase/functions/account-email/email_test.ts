import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { POSTAL_ADDRESS, sendEmail, SENDER } from "../_shared/resend.ts";
import {
  formatDate,
  planName,
  renewalDeadline,
  type SubscriptionDetails,
  subscriptionDetails,
  subscriptionBillingProblemEmail,
  subscriptionEndedEmail,
  subscriptionEndingEmail,
  subscriptionPlanChangedEmail,
  subscriptionRefundedEmail,
  subscriptionRenewalOnEmail,
  subscriptionRenewedEmail,
  subscriptionStartedEmail,
  welcomeEmail,
} from "./email.ts";

const details = (overrides: Partial<SubscriptionDetails> = {}): SubscriptionDetails => ({
  trial: false,
  plan: "Foon Family monthly plan",
  date: "December 11, 2026",
  deadline: "8:00 PM EST on December 10, 2026",
  billingEnforced: false,
  grace: false,
  revoked: false,
  immediate: false,
  ...overrides,
});

const all = () => [
  welcomeEmail(),
  subscriptionStartedEmail(details({ trial: true })),
  subscriptionStartedEmail(details()),
  subscriptionEndingEmail(details()),
  subscriptionEndedEmail(details()),
  subscriptionEndedEmail(details({ billingEnforced: true })),
  subscriptionRenewedEmail(details()),
  subscriptionBillingProblemEmail(details({ grace: true })),
  subscriptionBillingProblemEmail(details()),
  subscriptionRenewalOnEmail(details()),
  subscriptionPlanChangedEmail(details()),
  subscriptionPlanChangedEmail(details({ immediate: true })),
  subscriptionRefundedEmail(details()),
  subscriptionRefundedEmail(details({ revoked: true })),
];

Deno.test("every email ends with the sender, postal address and support address, and has no unsubscribe link", () => {
  for (const email of all()) {
    for (const line of [SENDER, ...POSTAL_ADDRESS, "support@getfoon.com"]) {
      assertStringIncludes(email.text, line);
      assertStringIncludes(email.html, line);
    }
    assert(!email.text.toLowerCase().includes("unsubscribe"), email.subject);
  }
});

Deno.test("no email uses an em dash", () => {
  const emDash = String.fromCharCode(0x2014);
  for (const email of all()) assert(!email.text.includes(emDash) && !email.html.includes(emDash), email.subject);
});

Deno.test("the welcome says what Foon does, how to invite, and where to write", () => {
  const email = welcomeEmail("https://preview.example/");
  assertEquals(email.subject, "Welcome to Foon");
  assertStringIncludes(email.text, "Build my week");
  assertStringIncludes(email.text, "open Family, tap a person, then Invite");
  assertStringIncludes(email.text, "https://preview.example/privacy");
  assertStringIncludes(email.html, "<li>");
});

Deno.test("subscription notices give the plan, the date and how to manage it, and don't sell", () => {
  for (const email of all().slice(1)) {
    assertStringIncludes(email.text, "tap your name, then Subscriptions");
    // Apple's retry without a grace period has no date to give.
    if (email.subject.startsWith("Apple couldn't") && !email.text.includes("keeps everything")) continue;
    assertStringIncludes(email.text, "December 11, 2026");
    assert(!/upgrade|annual plan|save \d/i.test(email.text), email.subject);
  }
  for (const email of [all()[1], all()[2], all()[4]]) assertStringIncludes(email.text, "Foon Family monthly plan");
});

Deno.test("the renewal says when the next one is, and that Apple sends the receipt", () => {
  const email = subscriptionRenewedEmail(details());
  assertEquals(email.subject, "Your Foon subscription renewed");
  assertStringIncludes(email.text, "Your family's Foon Family monthly plan renewed");
  assertStringIncludes(email.text, "runs until December 11, 2026");
  assertStringIncludes(email.text, "Apple emails the receipt");
});

Deno.test("a billing problem says what to do, and in a grace period when access continues until", () => {
  const grace = subscriptionBillingProblemEmail(details({ grace: true }));
  assertEquals(grace.subject, "Apple couldn't charge for your Foon subscription");
  assertStringIncludes(grace.text, "couldn't charge the payment method for your family's Foon Family monthly plan");
  assertStringIncludes(grace.text, "keeps everything Foon offers until December 11, 2026");
  assertStringIncludes(grace.text, "tap your name, then Subscriptions, and update your payment method");
  const plain = subscriptionBillingProblemEmail(details());
  assertStringIncludes(plain.text, "Apple will try again");
  assert(!plain.text.includes("December 11, 2026"));
  assertStringIncludes(plain.text, "update your payment method");
});

Deno.test("turning renewal back on says when it renews", () => {
  const email = subscriptionRenewalOnEmail(details());
  assertEquals(email.subject, "Your Foon subscription will renew");
  assertStringIncludes(email.text, "Apple will renew it on December 11, 2026");
});

Deno.test("a plan change names the new plan: at the next renewal, or at once for an upgrade", () => {
  const plan = "Foon Family yearly plan";
  const later = subscriptionPlanChangedEmail(details({ plan }));
  assertEquals(later.subject, "Your Foon plan is changing");
  assertStringIncludes(later.text, `will change to the ${plan} when the current period ends on December 11, 2026`);
  assertStringIncludes(later.text, "Until then nothing changes");
  const now = subscriptionPlanChangedEmail(details({ plan, immediate: true }));
  assertEquals(now.subject, "Your Foon plan has changed");
  assertStringIncludes(now.text, `is now the ${plan}`);
});

Deno.test("a refund and a Family Sharing removal say why access ended, and what changes", () => {
  const refund = subscriptionRefundedEmail(details());
  assertEquals(refund.subject, "Your Foon subscription was refunded");
  assertStringIncludes(
    refund.text,
    "Apple refunded your family's Foon Family monthly plan, so access ended on December 11, 2026",
  );
  assertStringIncludes(refund.text, "free for every family during the beta");
  const revoked = subscriptionRefundedEmail(details({ revoked: true, billingEnforced: true }));
  assertEquals(revoked.subject, "Your Foon subscription access has ended");
  assertStringIncludes(revoked.text, "because Family Sharing for it was ended");
  assertStringIncludes(revoked.text, "Foon is now view-only for your family");
  assertStringIncludes(revoked.text, "Nothing in your household was deleted");
});

Deno.test("the trial email says the plain deadline to avoid being charged", () => {
  const email = subscriptionStartedEmail(details({ trial: true }));
  assertStringIncludes(email.text, "To avoid being charged, turn off renewal before 8:00 PM EST on December 10, 2026.");
  assert(!email.text.includes("24 hours"));
});

Deno.test("the ended email says what changes: nothing in the beta, view-only once billing is on", () => {
  assertStringIncludes(subscriptionEndedEmail(details()).text, "free for every family during the beta");
  const enforced = subscriptionEndedEmail(details({ billingEnforced: true })).text;
  assertStringIncludes(enforced, "Foon is now view-only for your family");
  assertStringIncludes(enforced, "paused until you subscribe again");
  assertStringIncludes(enforced, "Nothing in your household was deleted");
});

Deno.test("dates are the household's own: a late-evening US expiry is the previous local day", () => {
  assertEquals(formatDate("2026-12-12T01:00:00Z", "America/New_York"), "December 11, 2026");
  assertEquals(formatDate("2026-12-12T01:00:00Z", "America/Los_Angeles"), "December 11, 2026");
  assertEquals(formatDate("2026-12-12T01:00:00Z"), "December 12, 2026");
  assertEquals(formatDate("2026-12-12T01:00:00Z", "Not/AZone"), "December 12, 2026", "an unknown zone is UTC");
  assertEquals(formatDate("not a date"), null);
});

Deno.test("the renewal deadline is 24 hours before the end, in the household's zone", () => {
  assertEquals(renewalDeadline("2026-12-12T01:00:00Z", "America/New_York"), "8:00 PM EST on December 10, 2026");
  assertEquals(renewalDeadline("2026-12-12T01:00:00Z"), "1:00 AM UTC on December 11, 2026");
  assertEquals(renewalDeadline("nope"), null);
});

Deno.test("a payload becomes the email's details", () => {
  assertEquals(
    subscriptionDetails({
      trial: true,
      product_id: "foon.family.annual",
      ends_at: "2026-12-12T01:00:00+00:00",
      time_zone: "America/New_York",
      billing_enforced: false,
    }),
    {
      trial: true,
      plan: "Foon Family yearly plan",
      date: "December 11, 2026",
      deadline: "8:00 PM EST on December 10, 2026",
      billingEnforced: false,
      grace: false,
      revoked: false,
      immediate: false,
    },
  );
  assertEquals(
    subscriptionDetails({ ends_at: "2026-12-12T01:00:00Z", grace: true, revoked: true, immediate: true }),
    {
      trial: false,
      plan: "Foon subscription",
      date: "December 12, 2026",
      deadline: "1:00 AM UTC on December 11, 2026",
      billingEnforced: false,
      grace: true,
      revoked: true,
      immediate: true,
    },
  );
  assertEquals(subscriptionDetails({ trial: true }), null);
  assertEquals(subscriptionDetails(null), null);
});

Deno.test("plans are named from the product id", () => {
  assertEquals(planName("foon.family.monthly"), "Foon Family monthly plan");
  assertEquals(planName("foon.family.founding"), "Foon Founding Family yearly plan");
  assertEquals(planName("something.else"), "Foon subscription");
  assertEquals(planName(undefined), "Foon subscription");
});

Deno.test("HTML is escaped", () => {
  const email = subscriptionEndingEmail(details({ date: "<b>soon</b>" }));
  assertStringIncludes(email.html, "&lt;b&gt;soon&lt;/b&gt;");
  assert(!email.html.includes("<b>soon"));
});

Deno.test("an idempotency key goes to Resend as a request header, not an email header", async () => {
  let request: RequestInit | undefined;
  const post = (_url: string | URL | Request, init?: RequestInit) => {
    request = init;
    return Promise.resolve(new Response("{}", { status: 200 }));
  };
  await sendEmail({ apiKey: "k", from: "f" }, {
    to: "t@example.com",
    subject: "s",
    text: "t",
    html: "h",
    idempotencyKey: "account-email/row-1",
  }, post as typeof fetch);
  assertEquals((request?.headers as Record<string, string>)["Idempotency-Key"], "account-email/row-1");
  assert(!("idempotencyKey" in JSON.parse(String(request?.body))));
});
