import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { POSTAL_ADDRESS, SENDER } from "../_shared/resend.ts";
import {
  bodyBlocks,
  foundingUpdateEmail,
  nightLine,
  parsePostalAddress,
  parseUpdate,
  weeklyPlanDetails,
  weeklyPlanEmail,
} from "./opt_in_email.ts";

const unsubscribeUrl = "https://x.supabase.co/functions/v1/account-email?unsubscribe=weekly_plan.u.sig";

const week = {
  week_start: "2026-11-16",
  nights: [
    { date: "2026-11-16", meal: "Tacos", quick_pick: null, away: false },
    { date: "2026-11-17", meal: null, quick_pick: "fend_for_yourselves", away: false },
    { date: "2026-11-18", meal: null, quick_pick: null, away: true },
    { date: "2026-11-19", meal: null, quick_pick: null, away: false },
    { date: "2026-11-20", meal: "<b>Pizza</b>\nnight", quick_pick: null, away: false },
  ],
};

Deno.test("each night reads as its date and its dinner", () => {
  const details = weeklyPlanDetails(week)!;
  assertEquals(details.nights.map(nightLine), [
    "Monday, November 16: Tacos",
    "Tuesday, November 17: Fend for yourselves",
    "Wednesday, November 18: Away",
    "Thursday, November 19: Nothing planned yet",
    "Friday, November 20: <b>Pizza</b> night",
  ]);
});

Deno.test("a payload without a week isn't one it can write", () => {
  assertEquals(weeklyPlanDetails(null), null);
  assertEquals(weeklyPlanDetails({ nights: [] }), null);
  assertEquals(weeklyPlanDetails({ week_start: "soon", nights: [] }), null);
});

Deno.test("the weekly plan email lists the dinners, links to Foon, and unsubscribes in one tap", () => {
  const email = weeklyPlanEmail(weeklyPlanDetails(week)!, { siteUrl: "https://getfoon.com/", unsubscribeUrl });
  assertEquals(email.subject, "Your family's dinners for the week of November 16");
  assertStringIncludes(email.text, "- Monday, November 16: Tacos");
  assertStringIncludes(email.text, "https://getfoon.com");
  assertStringIncludes(email.text, `Unsubscribe (turns off this weekly email): ${unsubscribeUrl}`);
  assertStringIncludes(email.text, "you turned on the weekly plan email");
  for (const line of [SENDER, ...POSTAL_ADDRESS]) assertStringIncludes(email.text, line);
  assertEquals(email.headers, {
    "List-Unsubscribe": `<${unsubscribeUrl}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  });
  assertStringIncludes(email.html, "&lt;b&gt;Pizza&lt;/b&gt;", "the family's own words are escaped");
  assert(!email.html.includes("<b>Pizza"));
});

Deno.test("never anything about allergies or who's home", () => {
  const email = weeklyPlanEmail(weeklyPlanDetails(week)!, { siteUrl: "https://getfoon.com", unsubscribeUrl });
  for (const word of ["allerg", "calorie", "nutrition"]) assert(!email.text.toLowerCase().includes(word));
});

Deno.test("an update's body becomes paragraphs and lists", () => {
  assertEquals(bodyBlocks("Hello,\nfamilies.\n\n- One\n- Two\n\n## Next\n\n* Three"), [
    "Hello, families.",
    { list: ["One", "Two"] },
    "Next",
    { list: ["Three"] },
  ]);
});

Deno.test("an update comes as markdown with a # subject line, or as a subject and body", () => {
  assertEquals(parseUpdate({ markdown: "# Big news\n\nWe launched.\n" }), {
    subject: "Big news",
    body: "We launched.",
  });
  assertEquals(parseUpdate({ subject: " Big news ", body: " We launched. " }), {
    subject: "Big news",
    body: "We launched.",
  });
  assertEquals(parseUpdate({ subject: "Override", markdown: "# Big news\n\nWe launched." }), {
    subject: "Override",
    body: "We launched.",
  }, "a typed subject wins over the file's");
  assertEquals(parseUpdate({ markdown: "No heading\n\nbody" }), null, "markdown needs its # subject");
  assertEquals(parseUpdate({ subject: "Hi" }), null);
  assertEquals(parseUpdate({ subject: "Two\nlines", body: "x" }), null, "a subject is one line");
  assertEquals(parseUpdate({ subject: "x".repeat(151), body: "x" }), null);
  assertEquals(parseUpdate({ subject: "Hi", body: "x".repeat(20_001) }), null);
  assertEquals(parseUpdate(null), null);
});

Deno.test("the postal address comes from EMAIL_POSTAL_ADDRESS, lines split by ; or newlines", () => {
  assertEquals(parsePostalAddress("1 Main St; Suite 2;Town, OH 44000"), ["1 Main St", "Suite 2", "Town, OH 44000"]);
  assertEquals(parsePostalAddress("1 Main St\nTown, OH 44000"), ["1 Main St", "Town, OH 44000"]);
  assertEquals(parsePostalAddress(undefined), null);
  assertEquals(parsePostalAddress(" ; "), null);
});

Deno.test("a founding update names who sent it, the postal address, why they get it, and how to stop", () => {
  const url = "https://x/functions/v1/account-email?unsubscribe=founding_updates.u.sig";
  const email = foundingUpdateEmail({ subject: "Big news", body: "We launched.\n\n- Lists\n- Polls" }, {
    unsubscribeUrl: url,
    postalAddress: ["PO Box 1", "Town, OH 44000"],
  });
  assertEquals(email.subject, "Big news");
  assertStringIncludes(email.text, "We launched.");
  assertStringIncludes(email.text, "- Polls");
  assertStringIncludes(email.text, "PO Box 1\nTown, OH 44000");
  assertStringIncludes(email.text, SENDER);
  assertStringIncludes(email.text, "you turned on founding-family updates in Foon");
  assertStringIncludes(email.text, `Unsubscribe (turns off founding-family updates): ${url}`);
  assertEquals(email.headers?.["List-Unsubscribe"], `<${url}>`);
  assertEquals(email.headers?.["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
});
