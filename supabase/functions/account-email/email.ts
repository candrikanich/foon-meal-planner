// Foon's queued emails to adults about their own account (#48): the owner's welcome and subscription notices. All
// transactional, so they end with the sender, postal address and support address, and carry no unsubscribe link.
// English only. No value from the family goes into them (no names), only dates and our own words, and every value is
// escaped in the HTML.
import { SUPPORT_EMAIL, transactionalEmail as render } from "../_shared/email_layout.ts";
import type { Email } from "../_shared/resend.ts";

type Message = Omit<Email, "to">;

// "December 11, 2026". Dates are UTC: Foon doesn't know the reader's time zone here, and Apple's own receipt has the time.
export function formatDate(iso: string): string | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleDateString("en-US", { timeZone: "UTC", month: "long", day: "numeric", year: "numeric" });
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

export interface SubscriptionDetails {
  trial: boolean;
  // When the trial or paid period ends (started, ending) or ended (ended), formatted.
  date: string;
}

export function subscriptionStartedEmail(details: SubscriptionDetails): Message {
  return details.trial
    ? render("Your Foon free trial has started", [
      "Hi,",
      `Your family's Foon free trial has started. It runs until ${details.date}. After that, Apple renews it as a paid ` +
      "subscription unless you turn off renewal at least 24 hours before the trial ends.",
      manage,
      questions,
    ])
    : render("Your Foon subscription has started", [
      "Hi,",
      `Your family's Foon subscription has started. The current period runs until ${details.date}, and Apple renews it ` +
      "unless you turn off renewal at least 24 hours before then.",
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

export function subscriptionEndedEmail(details: SubscriptionDetails): Message {
  return render("Your Foon subscription has ended", [
    "Hi,",
    `Your family's Foon subscription ended on ${details.date}.`,
    "Nothing in your household was deleted: your plans, dishes and lists are still there.",
    manage,
    questions,
  ]);
}
