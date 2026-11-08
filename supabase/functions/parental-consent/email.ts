// The two emails of COPPA "email plus" (16 CFR 312.5(b)(2)(viii)), English only (decided 2026-11-08). Email 1 is the
// direct notice, mapped to 312.4(c)(1)(i)-(vii) below; email 2 confirms the parent's consent and says how to withdraw
// it, which the rule requires of the confirming step. The kid's first name is the only value put into either, and it's
// escaped in the HTML. Changing what either promises means a new TEXT_VERSION.
import { type Email, escapeHtml, POSTAL_ADDRESS, SENDER } from "../_shared/resend.ts";

export const TEXT_VERSION = "parental-invite-v3";
export const PRIVACY_URL = "https://getfoon.com/privacy";
export const CONTACT_EMAIL = "support@getfoon.com";

const footer = {
  text: ["--", SENDER, ...POSTAL_ADDRESS, CONTACT_EMAIL].join("\n"),
  html: `<p style="color:#6b6058;font-size:13px">${
    [SENDER, ...POSTAL_ADDRESS, CONTACT_EMAIL].map(escapeHtml).join("<br>")
  }</p>`,
};

// What Foon keeps about the kid, the same list the in-app wording (parental-invite-v2) gave.
const kept = (name: string) => [
  `what your family enters about ${name}: first name, avatar, allergies and schedule`,
  `what ${name} adds: requests, ratings, comments and list items`,
  "an age range from Apple (never a birthdate)",
  `${name}'s Apple sign-in (account ID and email) and a notification token`,
];

// A subject is one header line.
const oneLine = (value: string) => value.replace(/\s+/g, " ").trim();
const html = (paragraphs: string[]) => paragraphs.map((p) => `<p>${p}</p>`).join("\n");
const link = (url: string, label: string) => `<a href="${escapeHtml(url)}">${escapeHtml(label)}</a>`;
const list = (items: string[]) => `<ul>${items.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`;

export interface NoticeMessage {
  firstName: string;
  consentUrl: string;
  // Where the address came from: the parent's sign-in, or typed in Foon because the account had none.
  emailSource: "account" | "typed";
}

export function noticeEmail(message: NoticeMessage): Omit<Email, "to"> {
  const name = message.firstName;
  const n = escapeHtml(name);
  const whereFrom = message.emailSource === "account"
    ? "We used the email on your Foon sign-in."
    : "We used the email you typed in Foon.";
  const keptAddress = message.emailSource === "account"
    ? "We use your email address only to send this email and the one confirming your answer. We read it from your " +
      "sign-in and don't copy it anywhere else."
    : "We use the address you typed only to send this email and the one confirming your answer, and delete it once " +
      "that one is sent or this request ends.";
  const text = [
    "Hi,",
    "",
    `You asked to invite ${name} to Foon, your family's dinner planner, so ${name} can use it on their own device. ` +
    `Foon needs a parent's consent first. ${whereFrom} We haven't collected anything from ${name}.`,
    "",
    `Review and agree: ${message.consentUrl}`,
    "",
    `If you agree, Foon keeps:`,
    ...kept(name).map((item) => `- ${item}`),
    "",
    `It's used only to run Foon for your family, and everyone in your household can see it. We don't disclose it to ` +
    `anyone else. Only the services that run Foon for us handle it (Supabase hosts it; Apple delivers notifications), ` +
    `and it's never sold or used for ads.`,
    "",
    `If you don't agree, Foon collects nothing from ${name}, no invite can be made, and ${name} can't sign in.`,
    "",
    "This link works for 7 days. If you don't answer by then, the request lapses and nothing changes.",
    "",
    `You can withdraw your consent at any time: in Foon, open Family, then ${name}, then Withdraw consent, or use the ` +
    `link in the email we send once you agree. ${name} is signed out at once.`,
    "",
    keptAddress,
    "",
    `Privacy policy: ${PRIVACY_URL}`,
    `Questions: ${CONTACT_EMAIL}`,
    "",
    "If you didn't ask for this, ignore this email. Nothing happens without your answer.",
    "",
    footer.text,
  ].join("\n");
  const body = html([
    "Hi,",
    `You asked to invite ${n} to Foon, your family's dinner planner, so ${n} can use it on their own device. Foon ` +
    `needs a parent's consent first. ${whereFrom} We haven't collected anything from ${n}.`,
    link(message.consentUrl, "Review and agree"),
    "If you agree, Foon keeps:",
  ]) + "\n" + list(kept(name)) + "\n" + html([
    "It's used only to run Foon for your family, and everyone in your household can see it. We don't disclose it to " +
    "anyone else. Only the services that run Foon for us handle it (Supabase hosts it; Apple delivers notifications), " +
    "and it's never sold or used for ads.",
    `If you don't agree, Foon collects nothing from ${n}, no invite can be made, and ${n} can't sign in.`,
    "This link works for 7 days. If you don't answer by then, the request lapses and nothing changes.",
    `You can withdraw your consent at any time: in Foon, open Family, then ${n}, then Withdraw consent, or use the ` +
    `link in the email we send once you agree. ${n} is signed out at once.`,
    keptAddress,
    `${link(PRIVACY_URL, "Privacy policy")} · Questions: ${escapeHtml(CONTACT_EMAIL)}`,
    `<span style="color:#6b6058;font-size:13px">If you didn't ask for this, ignore this email. Nothing happens ` +
    `without your answer.</span>`,
  ]) + "\n" + footer.html;
  return { subject: `Confirm ${oneLine(name)} can use Foon`, text, html: body };
}

export interface ConfirmationMessage {
  firstName: string;
  withdrawUrl: string;
  // When the parent tapped I agree.
  agreedAt: string;
}

const agreedOn = (iso: string) =>
  new Intl.DateTimeFormat("en-US", { dateStyle: "long", timeStyle: "short", timeZone: "UTC" }).format(new Date(iso)) +
  " UTC";

export function confirmationEmail(message: ConfirmationMessage): Omit<Email, "to"> {
  const name = message.firstName;
  const n = escapeHtml(name);
  const when = agreedOn(message.agreedAt);
  const summary = (who: string) =>
    `Foon keeps what your family enters about ${who} (first name, avatar, allergies and schedule), what ${who} adds ` +
    `(requests, ratings, comments and list items), an age range from Apple, and ${who}'s Apple sign-in and a ` +
    `notification token. Only your household and the services that run Foon (Supabase for hosting, Apple for ` +
    `notifications) receive it, and it's never sold or used for ads.`;
  const text = [
    "Hi,",
    "",
    `On ${when} you agreed that ${name} can use Foon on their own device. ${summary(name)}`,
    "",
    `You can invite ${name} now: in Foon, open Family, then ${name}, then Invite.`,
    "",
    "You can withdraw this consent at any time:",
    `- Withdraw consent: ${message.withdrawUrl} (this link works for 30 days)`,
    `- or in Foon, open Family, then ${name}, then Withdraw consent.`,
    `Withdrawing signs ${name} out at once and cancels any invite.`,
    "",
    "If this wasn't you, withdraw now.",
    "",
    `Privacy policy: ${PRIVACY_URL}`,
    "",
    footer.text,
  ].join("\n");
  const body = html([
    "Hi,",
    `On ${escapeHtml(when)} you agreed that ${n} can use Foon on their own device. ${summary(n)}`,
    `You can invite ${n} now: in Foon, open Family, then ${n}, then Invite.`,
    "You can withdraw this consent at any time:",
  ]) + "\n" +
    `<ul><li>${link(message.withdrawUrl, "Withdraw consent")} (this link works for 30 days)</li>` +
    `<li>or in Foon, open Family, then ${n}, then Withdraw consent.</li></ul>\n` +
    html([
      `Withdrawing signs ${n} out at once and cancels any invite.`,
      "<strong>If this wasn't you, withdraw now.</strong>",
      link(PRIVACY_URL, "Privacy policy"),
    ]) + "\n" + footer.html;
  return { subject: `You agreed ${oneLine(name)} can use Foon`, text, html: body };
}
