import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { confirmationEmail, PRIVACY_URL, renewalNoticeEmail, type RenewalMessage } from "./email.ts";

const consentUrl = "https://x.supabase.co/functions/v1/parental-consent?consent=abc";
const message: RenewalMessage = {
  firstName: "Nora",
  consentUrl,
  emailSource: "account",
  summary: "Foon now confirms a parent's consent by email, and names the services that store and send your kid's " +
    "information.",
  agreedBefore: "2026-10-01T12:00:00Z",
  held: true,
  reminder: false,
};

Deno.test("the renewal notice has email 1's 312.4(c)(1) content, plus what changed and what a No means", () => {
  const { subject, text, html } = renewalNoticeEmail(message);
  assertEquals(subject, "Can Nora keep using Foon?");
  for (const body of [text, html]) {
    assertStringIncludes(body, "agreed on October 1, 2026"); // when a parent agreed before
    assertStringIncludes(body, "Foon now confirms a parent"); // what changed
    assertStringIncludes(body, "Until a parent agrees, Nora is signed out of Foon."); // (i) why, and what happens now
    assertStringIncludes(body, "Nothing is deleted");
    assertStringIncludes(body, "first name, avatar, allergies and schedule"); // (iii) what's collected
    assertStringIncludes(body, "Apple sign-in (account ID and email) and a notification token");
    assertStringIncludes(body, "We don't disclose it to"); // (iv) no disclosure
    assertStringIncludes(body, "never sold or used for ads");
    assertStringIncludes(body, "Nora stays signed out, Foon collects nothing new from Nora, and nothing is deleted");
    assertStringIncludes(body, PRIVACY_URL); // (v) the online notice
    assertStringIncludes(body, "Review and agree"); // (vi) how to consent
    assertStringIncludes(body, "This link works for 7 days"); // (vii) the request lapses
    assertStringIncludes(body, "To end your consent instead, withdraw it"); // how to withdraw instead
    assertStringIncludes(body, "then Nora, then Withdraw consent");
    assertStringIncludes(body, "34125 Center Ridge Road #1012"); // who sent it, CAN-SPAM postal address
    assertStringIncludes(body, "Foon, from The Recruiting Compass LLC");
    assertStringIncludes(body, "don't copy it anywhere else");
  }
  assertStringIncludes(text, `Review and agree: ${consentUrl}`);
  assertStringIncludes(text, `What changed: ${message.summary}`);
  assertStringIncludes(html, `href="${consentUrl}"`);
  assert(!text.includes("reminder"));
});

Deno.test("the reminder says so in the subject and the first line", () => {
  const { subject, text, html } = renewalNoticeEmail({ ...message, reminder: true });
  assertEquals(subject, "Reminder: Can Nora keep using Foon?");
  assert(text.startsWith("Hi,\n\nA reminder: we emailed your family about this a week ago, and no parent has agreed"));
  assertStringIncludes(html, "<strong>A reminder: we emailed your family about this a week ago");
});

Deno.test("without what changed or a date, the renewal notice still reads whole", () => {
  const { text } = renewalNoticeEmail({ ...message, summary: null, agreedBefore: null, emailSource: "typed" });
  assert(!text.includes("What changed"));
  assertStringIncludes(text, "A parent in your family agreed that Nora could use Foon");
  assertStringIncludes(text, "We used the email you typed in Foon.");
  assertStringIncludes(text, "delete it once that one is sent or this request ends");
});

Deno.test("a renewal asked for before the hold opens says the kid will be signed out, not that they are", () => {
  const { text, html } = renewalNoticeEmail({ ...message, held: false });
  for (const body of [text, html]) {
    assertStringIncludes(body, "Until a parent agrees, Nora will be signed out of Foon soon. Nothing is deleted");
    assertStringIncludes(body, "Nora is signed out, Foon collects nothing new from Nora");
    assert(!body.includes("Nora is signed out of Foon."));
    assert(!body.includes("stays signed out"));
    assertStringIncludes(body, "If no parent answers by then, Nora is signed out;");
  }
});

Deno.test("the renewal notice escapes the kid's name and the summary in the HTML, and keeps the subject one line", () => {
  const { subject, html } = renewalNoticeEmail({
    ...message,
    firstName: `<b>Al</b>\n& "Jo's"`,
    summary: "<script>x</script>",
  });
  assert(!html.includes("<b>Al</b>"));
  assert(!html.includes("<script>"));
  assertStringIncludes(html, "&lt;b&gt;Al&lt;/b&gt;");
  assertStringIncludes(html, "&lt;script&gt;x&lt;/script&gt;");
  assert(!subject.includes("\n"));
});

Deno.test("email 2 after a renewal says the kid can use Foon again, as /consent/done does", () => {
  const { subject, text, html } = confirmationEmail({
    firstName: "Nora",
    withdrawUrl: "https://x/w",
    agreedAt: "2026-11-08T15:04:00Z",
    renewal: true,
  });
  assertEquals(subject, "You agreed Nora can use Foon");
  for (const body of [text, html]) {
    assertStringIncludes(body, "Nora can use Foon again. If Foon asks Nora to join, invite them again");
    assert(!body.includes("You can invite Nora now"));
    assertStringIncludes(body, "If this wasn't you, withdraw now.");
  }
});
