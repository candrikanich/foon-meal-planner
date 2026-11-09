// The emails of COPPA "email plus" (16 CFR 312.5(b)(2)(viii)), English only (decided 2026-11-08). Email 1 is the
// direct notice, mapped to 312.4(c)(1)(i)-(vii) below; email 2 confirms the parent's consent and says how to withdraw
// it, which the rule requires of the confirming step. The renewal notice (#277) is email 1 for a kid whose consent was
// given to older wording, with what changed. The kid's first name is the only value from the family put into any of
// them, and it's escaped in the HTML. Changing what any of them promises means a new TEXT_VERSION and its
// agreement_versions row (docs/legal/README.md, Wording versions).
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

const disclosure =
  "It's used only to run Foon for your family, and everyone in your household can see it. We don't disclose it to " +
  "anyone else. Only the services that run Foon for us handle it (Supabase hosts it; Apple delivers notifications), " +
  "and it's never sold or used for ads.";

type EmailSource = "account" | "typed";

const whereFromLine = (source: EmailSource) =>
  source === "account" ? "We used the email on your Foon sign-in." : "We used the email you typed in Foon.";

const keptAddressLine = (source: EmailSource) =>
  source === "account"
    ? "We use your email address only to send this email and the one confirming your answer. We read it from your " +
      "sign-in and don't copy it anywhere else."
    : "We use the address you typed only to send this email and the one confirming your answer, and delete it once " +
      "that one is sent or this request ends.";

// A subject is one header line.
const oneLine = (value: string) => value.replace(/\s+/g, " ").trim();
const html = (paragraphs: string[]) => paragraphs.map((p) => `<p>${p}</p>`).join("\n");
const link = (url: string, label: string) => `<a href="${escapeHtml(url)}">${escapeHtml(label)}</a>`;
const list = (items: string[]) => `<ul>${items.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`;

export interface NoticeMessage {
  firstName: string;
  consentUrl: string;
  // Where the address came from: the parent's sign-in, or typed in Foon because the account had none.
  emailSource: EmailSource;
}

export function noticeEmail(message: NoticeMessage): Omit<Email, "to"> {
  const name = message.firstName;
  const n = escapeHtml(name);
  const whereFrom = whereFromLine(message.emailSource);
  const keptAddress = keptAddressLine(message.emailSource);
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
    disclosure,
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
    disclosure,
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

export interface RenewalMessage extends NoticeMessage {
  // The registry's one-sentence "what changed" for the wording in force; null when the caller doesn't have it.
  summary: string | null;
  // When a parent last agreed for this kid (ISO), or null when unknown.
  agreedBefore: string | null;
  // Whether the kid is signed out already. False only in the hour between a wording change and the job that holds.
  held: boolean;
  // Whether the kid had signed in on their own device. False: there's nothing to sign out of, so the email never says
  // "signed out". Null when the database didn't say (before 20261119000000): worded by `held`, as before.
  wasLinked: boolean | null;
  // The one reminder, 7 days after the first email, when no parent has agreed yet.
  reminder: boolean;
}

const agreedDay = (iso: string) =>
  new Intl.DateTimeFormat("en-US", { dateStyle: "long", timeZone: "UTC" }).format(new Date(iso));

// The renewal notice: the same 312.4(c)(1) content as email 1, for a kid whose consent was given to older wording. A No
// keeps the kid signed out and deletes nothing (Chris, 2026-11-09); withdrawing is the way to end the consent.
export function renewalNoticeEmail(message: RenewalMessage): Omit<Email, "to"> {
  const name = message.firstName;
  const n = escapeHtml(name);
  const whereFrom = whereFromLine(message.emailSource);
  const keptAddress = keptAddressLine(message.emailSource);
  const reminderLine = message.reminder
    ? `A reminder: we emailed your family about this a week ago, and no parent has agreed yet.`
    : null;
  const before = message.agreedBefore
    ? `A parent in your family agreed on ${agreedDay(message.agreedBefore)} that ${name} could use Foon on their own ` +
      `device. Foon has changed what it asks parents to agree to since then, so we need a parent's consent again.`
    : `A parent in your family agreed that ${name} could use Foon on their own device. Foon has changed what it asks ` +
      `parents to agree to since then, so we need a parent's consent again.`;
  const whatChanged = message.summary ? `What changed: ${message.summary}` : null;
  const neverSignedIn = message.wasLinked === false;
  const until = neverSignedIn
    ? `Until a parent agrees, ${name} can't use Foon on their own device.`
    : message.held
    ? `Until a parent agrees, ${name} is signed out of Foon.`
    : `Until a parent agrees, ${name} will be signed out of Foon soon.`;
  const signedOut =
    `${until} Nothing is deleted: ${name}'s profile and everything your family added stay as they are. ${whereFrom}`;
  // What a No or no answer leaves: the same as now.
  const staysOut = neverSignedIn
    ? `${name} still can't use Foon on their own device`
    : `${name} ${message.held ? "stays" : "is"} signed out`;
  const ifNot = `If you don't agree, ${staysOut}, Foon collects nothing new from ${name}, and nothing is deleted.`;
  const lapse = `This link works for 7 days. If no parent answers by then, ${staysOut}; you can ask for a new email ` +
    `in Foon (Family, then ${name}).`;
  const withdraw = (who: string) =>
    `To end your consent instead, withdraw it: in Foon, open Family, then ${who}, then Withdraw consent. Then what ` +
    `${who} added is erased after 30 days.`;
  const anyParent = "Any parent in your family can agree, and one is enough.";

  const text = [
    "Hi,",
    "",
    ...(reminderLine ? [reminderLine, ""] : []),
    before,
    ...(whatChanged ? ["", whatChanged] : []),
    "",
    signedOut,
    "",
    `Review and agree: ${message.consentUrl}`,
    "",
    `If you agree, Foon keeps:`,
    ...kept(name).map((item) => `- ${item}`),
    "",
    disclosure,
    "",
    ifNot,
    "",
    lapse,
    "",
    withdraw(name),
    "",
    anyParent,
    "",
    keptAddress,
    "",
    `Privacy policy: ${PRIVACY_URL}`,
    `Questions: ${CONTACT_EMAIL}`,
    "",
    footer.text,
  ].join("\n");
  const body = html([
    "Hi,",
    ...(reminderLine ? [`<strong>${escapeHtml(reminderLine)}</strong>`] : []),
    escapeHtml(before),
    ...(whatChanged ? [`<strong>What changed:</strong> ${escapeHtml(message.summary ?? "")}`] : []),
    escapeHtml(signedOut),
    link(message.consentUrl, "Review and agree"),
    "If you agree, Foon keeps:",
  ]) + "\n" + list(kept(name)) + "\n" + html([
    disclosure,
    escapeHtml(ifNot),
    escapeHtml(lapse),
    withdraw(n),
    anyParent,
    keptAddress,
    `${link(PRIVACY_URL, "Privacy policy")} · Questions: ${escapeHtml(CONTACT_EMAIL)}`,
  ]) + "\n" + footer.html;
  const subject = `Can ${oneLine(name)} keep using Foon?`;
  return { subject: message.reminder ? `Reminder: ${subject}` : subject, text, html: body };
}

export interface ConfirmationMessage {
  firstName: string;
  withdrawUrl: string;
  // When the parent tapped I agree.
  agreedAt: string;
  // A renewal links the kid's account back, so there's no invite to send unless that account is gone.
  renewal: boolean;
}

// What to do next, the same words as the site's /consent/done.
const nextStep = (name: string, renewal: boolean) =>
  renewal
    ? `${name} can use Foon again. If Foon asks ${name} to join, invite them again: in Foon, open Family, then ` +
      `${name}, then Invite.`
    : `You can invite ${name} now: in Foon, open Family, then ${name}, then Invite.`;

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
    nextStep(name, message.renewal),
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
    nextStep(n, message.renewal),
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
