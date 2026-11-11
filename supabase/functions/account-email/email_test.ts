import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { POSTAL_ADDRESS, SENDER } from "../_shared/resend.ts";
import {
  formatDate,
  subscriptionEndedEmail,
  subscriptionEndingEmail,
  subscriptionStartedEmail,
  welcomeEmail,
} from "./email.ts";

const all = () => [
  welcomeEmail(),
  subscriptionStartedEmail({ trial: true, date: "December 11, 2026" }),
  subscriptionStartedEmail({ trial: false, date: "December 11, 2026" }),
  subscriptionEndingEmail({ trial: false, date: "December 11, 2026" }),
  subscriptionEndedEmail({ trial: false, date: "December 11, 2026" }),
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

Deno.test("subscription notices give the date and how to manage it, and don't sell", () => {
  for (const email of all().slice(1)) {
    assertStringIncludes(email.text, "December 11, 2026");
    assertStringIncludes(email.text, "tap your name, then Subscriptions");
    assert(!/upgrade|annual plan|save \d/i.test(email.text), email.subject);
  }
  assertStringIncludes(subscriptionEndedEmail({ trial: false, date: "x" }).text, "Nothing in your household was deleted");
});

Deno.test("dates are written out in UTC, and a bad one is refused", () => {
  assertEquals(formatDate("2026-12-11T23:30:00Z"), "December 11, 2026");
  assertEquals(formatDate("2026-12-11T23:30:00-05:00"), "December 12, 2026");
  assertEquals(formatDate("not a date"), null);
});

Deno.test("HTML is escaped", () => {
  const email = subscriptionEndingEmail({ trial: false, date: "<b>soon</b>" });
  assertStringIncludes(email.html, "&lt;b&gt;soon&lt;/b&gt;");
  assert(!email.html.includes("<b>soon"));
});
