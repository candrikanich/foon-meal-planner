// Foon's queued emails to adults about their own account (#48): the owner's welcome and subscription notices. All
// transactional, so they end with the sender, postal address and support address, and carry no unsubscribe link.
// English only. No value from the family goes into them (no names), only dates and our own words, and every value is
// escaped in the HTML.
import { SUPPORT_EMAIL, transactionalEmail as render } from "../_shared/email_layout.ts";
import type { Email } from "../_shared/resend.ts";

type Message = Omit<Email, "to">;

// The household's time zone when it's one Intl knows, else UTC.
function knownZone(zone: string | undefined): string {
  if (!zone) return "UTC";
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return zone;
  } catch {
    return "UTC";
  }
}

// "December 11, 2026", in the household's time zone (UTC when it's missing or unknown).
export function formatDate(iso: string, zone?: string): string | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleDateString("en-US", {
    timeZone: knownZone(zone),
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

// Apple renews unless renewal is turned off at least 24 hours before the period ends: "8:00 PM EST on December 10,
// 2026", so nobody has to do the arithmetic.
export function renewalDeadline(iso: string, zone?: string): string | null {
  const ends = new Date(iso);
  if (Number.isNaN(ends.getTime())) return null;
  const deadline = new Date(ends.getTime() - 24 * 60 * 60 * 1000);
  const timeZone = knownZone(zone);
  // Some ICU versions put a narrow no-break space before AM/PM; plain spaces read the same everywhere.
  const time = deadline.toLocaleTimeString("en-US", { timeZone, hour: "numeric", minute: "2-digit", timeZoneName: "short" })
    .replace(/[  ]/g, " ");
  return `${time} on ${formatDate(deadline.toISOString(), timeZone)}`;
}

// Foon's products (app-store-notifications/products.ts) in words.
const planNames: Record<string, string> = {
  "foon.family.monthly": "Foon Family monthly plan",
  "foon.family.annual": "Foon Family yearly plan",
  "foon.family.founding": "Foon Founding Family yearly plan",
};
export const planName = (productId: unknown) =>
  (typeof productId === "string" ? planNames[productId] : undefined) ?? "Foon subscription";

export interface SubscriptionDetails {
  trial: boolean;
  plan: string;
  // When the trial or paid period ends (started, ending, renewed as the next renewal, renewal_on, plan_changed), when
  // grace ends (billing_problem in a grace period), or when access ended (ended, refunded), formatted.
  date: string;
  // The last moment to turn off renewal before Apple charges (started).
  deadline: string;
  // Whether a household without a subscription is view-only (app_config.billing_enforced when it was queued).
  billingEnforced: boolean;
  // billing_problem: Apple is retrying and the family keeps access until `date`.
  grace: boolean;
  // refunded: Family Sharing was removed rather than a refund given.
  revoked: boolean;
  // plan_changed: an upgrade, in force already; otherwise it takes over at the next renewal.
  immediate: boolean;
}

// What a subscription row's payload says, in words; null when it has no usable date.
export function subscriptionDetails(payload: Record<string, unknown> | null): SubscriptionDetails | null {
  const endsAt = payload?.ends_at;
  const zone = typeof payload?.time_zone === "string" ? payload.time_zone : undefined;
  if (typeof endsAt !== "string") return null;
  const date = formatDate(endsAt, zone);
  const deadline = renewalDeadline(endsAt, zone);
  if (!date || !deadline) return null;
  return {
    trial: payload?.trial === true,
    plan: planName(payload?.product_id),
    date,
    deadline,
    billingEnforced: payload?.billing_enforced === true,
    grace: payload?.grace === true,
    revoked: payload?.revoked === true,
    immediate: payload?.immediate === true,
  };
}

const manage = "To manage it, open Settings on your iPhone or iPad, tap your name, then Subscriptions.";
const questions = `Questions? Write to ${SUPPORT_EMAIL}.`;

export const DEFAULT_SITE_URL = "https://getfoon.com";

export function welcomeEmail(siteUrl = DEFAULT_SITE_URL): Message {
  return render("Welcome to Foon", [
    "Hi,",
    "Your family is set up in Foon. Here's what it does for you:",
    {
      list: [
        "Build my week drafts the week's dinners from your family's own dishes.",
        "Everyone can suggest dishes, rate dinners and offer to cook, so planning isn't one person's job.",
        "The shopping list fills itself from the week's plan.",
      ],
    },
    "Bring your family in: open Family, tap a person, then Invite.",
    `How Foon looks after your family's data: ${siteUrl.replace(/\/+$/, "")}/privacy`,
    questions,
  ]);
}

export function subscriptionStartedEmail(details: SubscriptionDetails): Message {
  return details.trial
    ? render("Your Foon free trial has started", [
      "Hi,",
      `Your family's free trial of the ${details.plan} has started. It runs until ${details.date}, and then Apple ` +
      "renews it as a paid subscription.",
      `To avoid being charged, turn off renewal before ${details.deadline}.`,
      manage,
      questions,
    ])
    : render("Your Foon subscription has started", [
      "Hi,",
      `Your family's ${details.plan} has started. The current period runs until ${details.date}, and then Apple ` +
      "renews it.",
      `To avoid the next charge, turn off renewal before ${details.deadline}.`,
      manage,
      questions,
    ]);
}

export function subscriptionEndingEmail(details: SubscriptionDetails): Message {
  return render("Your Foon subscription won't renew", [
    "Hi,",
    `Renewal is turned off for your family's Foon subscription, so it ends on ${details.date}. Your family keeps ` +
    "everything Foon offers until then.",
    "If that's not what you meant, you can turn renewal back on. " + manage,
    questions,
  ]);
}

// What ending means for the family, said the same way whether it ran out or was refunded.
const afterAccessEnds = (details: SubscriptionDetails) => [
  details.billingEnforced
    ? "Foon is now view-only for your family. Everyone can still see everything, check things off on a shopping " +
      "trip and export your data, but building and editing the week's plan, editing dishes and adding to lists are " +
      "paused until you subscribe again."
    : "Foon is free for every family during the beta, so nothing changes for yours for now.",
  "Nothing in your household was deleted: your plans, dishes and lists are still there.",
];

export function subscriptionEndedEmail(details: SubscriptionDetails): Message {
  return render("Your Foon subscription has ended", [
    "Hi,",
    `Your family's ${details.plan} ended on ${details.date}.`,
    ...afterAccessEnds(details),
    manage,
    questions,
  ]);
}

export function subscriptionRenewedEmail(details: SubscriptionDetails): Message {
  return render("Your Foon subscription renewed", [
    "Hi,",
    `Your family's ${details.plan} renewed. The new period runs until ${details.date}, and then Apple renews it ` +
    "again unless renewal is turned off. Apple emails the receipt for each payment.",
    manage,
    questions,
  ]);
}

export function subscriptionBillingProblemEmail(details: SubscriptionDetails): Message {
  return render("Apple couldn't charge for your Foon subscription", [
    "Hi,",
    `Apple couldn't charge the payment method for your family's ${details.plan}.`,
    details.grace
      ? `Your family keeps everything Foon offers until ${details.date} while Apple tries again.`
      : "Apple keeps trying for up to 60 days.",
    ...(details.grace ? [] : afterAccessEnds(details)),
    "To fix it, open Settings on your iPhone or iPad, tap your name, then Subscriptions, and update your payment " +
    "method there.",
    questions,
  ]);
}

export function subscriptionRenewalOnEmail(details: SubscriptionDetails): Message {
  return render("Your Foon subscription will renew", [
    "Hi,",
    `Renewal is turned back on for your family's ${details.plan}. Apple will renew it on ${details.date}, and ` +
    "emails the receipt each time.",
    "If that's not what you meant, you can turn renewal off again. " + manage,
    questions,
  ]);
}

export function subscriptionPlanChangedEmail(details: SubscriptionDetails): Message {
  return details.immediate
    ? render("Your Foon plan has changed", [
      "Hi,",
      `Your family's Foon subscription is now the ${details.plan}. The new period runs until ${details.date}, and ` +
      "then Apple renews it.",
      manage,
      questions,
    ])
    : render("Your Foon plan is changing", [
      "Hi,",
      `Your family's Foon subscription will change to the ${details.plan} when the current period ends on ` +
      `${details.date}. Until then nothing changes.`,
      "If that's not what you meant, you can change it back before then. " + manage,
      questions,
    ]);
}

export function subscriptionRefundedEmail(details: SubscriptionDetails): Message {
  return details.revoked
    ? render("Your Foon subscription access has ended", [
      "Hi,",
      `Apple removed your family's access to the ${details.plan} on ${details.date}, because Family Sharing for it ` +
      "was ended.",
      ...afterAccessEnds(details),
      manage,
      questions,
    ])
    : render("Your Foon subscription was refunded", [
      "Hi,",
      `Apple refunded your family's ${details.plan}, so access ended on ${details.date}.`,
      ...afterAccessEnds(details),
      manage,
      questions,
    ]);
}
