import { assert, assertEquals, assertStringIncludes, assertThrows } from "@std/assert";
import type { Email } from "../_shared/resend.ts";
import {
  handleInviteEmail,
  INVITE_SUBJECT,
  inviteEmail,
  type InviteEmailDeps,
  inviteLink,
  InviteRefusedError,
  type InviteReservation,
  plainName,
  reservationFromRow,
} from "./invite.ts";

const MEMBER = "00000000-0000-0000-0000-0000000000a5";
const ADDRESS = "gran.private@example.com";

const reserved: Extract<InviteReservation, { outcome: "send" }> = {
  outcome: "send",
  sendId: 41,
  code: "THEAN-7KQ4-M9XP",
  firstName: "Gran",
  inviter: "Alice",
  household: "The Andersons",
  expiresAt: "2026-11-18T15:00:00Z",
  timeZone: "America/Chicago",
};

function fakeDeps(answer: InviteReservation | Error = reserved, overrides: Partial<InviteEmailDeps> = {}) {
  const sent: Email[] = [];
  const reservations: { jwt: string; memberId: string; code: string }[] = [];
  const logs: string[] = [];
  const deps: InviteEmailDeps = {
    userFromToken: (jwt) => Promise.resolve(jwt === "good-jwt" ? "a0000000-0000-0000-0000-00000000000a" : null),
    send: (email) => {
      sent.push(email);
      return Promise.resolve();
    },
    reserve: (jwt, memberId, code) => {
      reservations.push({ jwt, memberId, code });
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
    },
    log: (message, detail) => logs.push(`${message} ${detail ?? ""}`),
    ...overrides,
  };
  return { deps, sent, reservations, logs };
}

const ask = (body: unknown, { jwt = "good-jwt" as string | null, method = "POST" } = {}) =>
  new Request("https://x/functions/v1/account-email?invite=1", {
    method,
    headers: jwt === null ? {} : { Authorization: `Bearer ${jwt}` },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

const good = { memberId: MEMBER, code: "THEAN-7KQ4-M9XP", email: ADDRESS };

Deno.test("only a POST from a signed-in parent goes anywhere", async () => {
  const { deps, reservations, sent } = fakeDeps();
  assertEquals((await handleInviteEmail(ask(good, { method: "GET" }), deps)).status, 405);
  assertEquals((await handleInviteEmail(ask(good, { jwt: null }), deps)).status, 401);
  assertEquals((await handleInviteEmail(ask(good, { jwt: "expired" }), deps)).status, 401);
  assertEquals(reservations, []);
  assertEquals(sent, []);
});

Deno.test("a typed address is checked strictly before anything is reserved", async () => {
  for (const email of ["", "gran", "gran@", "@example.com", "gran@example", "a b@example.com", "x".repeat(250) + "@e.com"]) {
    const { deps, reservations } = fakeDeps();
    const response = await handleInviteEmail(ask({ ...good, email }), deps);
    assertEquals(response.status, 400, email);
    assertEquals(await response.json(), { error: "bad_email" });
    assertEquals(reservations, []);
  }
});

Deno.test("the member id and code are checked too", async () => {
  for (const body of [
    { ...good, memberId: "gran" },
    { ...good, code: "short" },
    { ...good, code: "THEAN-7KQ4-M9XP<script>" },
    { email: ADDRESS, memberId: MEMBER },
    null,
  ]) {
    const { deps, reservations } = fakeDeps();
    const response = await handleInviteEmail(ask(body), deps);
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "bad_request" });
    assertEquals(reservations, []);
  }
});

Deno.test("sends one email with the link, the code, who invited them and the household", async () => {
  const { deps, sent, reservations } = fakeDeps();
  const response = await handleInviteEmail(ask({ ...good, email: `  ${ADDRESS} ` }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "sent" }, "the address isn't echoed back");
  assertEquals(reservations, [{ jwt: "good-jwt", memberId: MEMBER, code: "THEAN-7KQ4-M9XP" }],
    "the database checks the request as the parent");
  assertEquals(sent.length, 1);
  assertEquals(sent[0].to, ADDRESS);
  assertEquals(sent[0].subject, INVITE_SUBJECT);
  assertEquals(sent[0].idempotencyKey, "invite-email/41");
  for (const part of [sent[0].text, sent[0].html]) {
    assertStringIncludes(part, "https://www.getfoon.com/invite?code=THEAN-7KQ4-M9XP");
    assertStringIncludes(part, "THEAN-7KQ4-M9XP");
    assertStringIncludes(part, "November 18, 2026");
    assertStringIncludes(part, "Foon used it only to send this email");
  }
  assert(!sent[0].headers, "transactional: no unsubscribe headers");
});

Deno.test("it emails the code the database rebuilt, not the text the app sent", async () => {
  const { deps, sent } = fakeDeps();
  await handleInviteEmail(ask({ ...good, code: "thean 7kq4 m9xp" }), deps);
  assertStringIncludes(sent[0].text, "enter this code: THEAN-7KQ4-M9XP");
});

Deno.test("refusals from the database: not a parent, or signed out", async () => {
  for (const [code, status, error] of [["42501", 403, "not_a_parent"], ["28000", 401, "not_signed_in"]] as const) {
    const { deps, sent } = fakeDeps(new InviteRefusedError(code));
    const response = await handleInviteEmail(ask(good), deps);
    assertEquals(response.status, status);
    assertEquals(await response.json(), { error });
    assertEquals(sent, []);
  }
});

Deno.test("a kid's profile, a claimed one, a stale code, email off and the limits send nothing", async () => {
  for (const [outcome, status] of [
    ["kid", 409],
    ["not_invitable", 409],
    ["wrong_code", 409],
    ["email_off", 503],
    ["rate_limited", 429],
  ] as const) {
    const { deps, sent } = fakeDeps({ outcome });
    const response = await handleInviteEmail(ask(good), deps);
    assertEquals(response.status, status, outcome);
    assertEquals(await response.json(), { error: outcome });
    assertEquals(sent, []);
  }
});

Deno.test("with no Resend key or sender, nothing is reserved, so no send is counted", async () => {
  const { deps, reservations } = fakeDeps(reserved, { send: null });
  const response = await handleInviteEmail(ask(good), deps);
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "email_off" });
  assertEquals(reservations, []);
});

Deno.test("the address is never logged or kept, even when the send fails", async () => {
  const { deps, logs } = fakeDeps(reserved, {
    send: () => Promise.reject(new Error("Resend answered 422")),
  });
  const response = await handleInviteEmail(ask(good), deps);
  assertEquals(response.status, 502);
  assertEquals(await response.json(), { error: "send_failed" });
  assertEquals(logs.length, 1);
  assertStringIncludes(logs[0], "invite 41 not sent");
  for (const line of logs) {
    assert(!line.includes(ADDRESS), "no address in the log");
    assert(!line.includes("THEAN"), "no code in the log");
  }
});

Deno.test("only the member id and code reach the database: the address has nowhere to be stored", async () => {
  const { deps, reservations } = fakeDeps();
  await handleInviteEmail(ask(good), deps);
  assert(!JSON.stringify(reservations).includes(ADDRESS));
});

Deno.test("a database failure is logged without the request", async () => {
  const { deps, logs, sent } = fakeDeps(new Error("connection reset"));
  const response = await handleInviteEmail(ask(good), deps);
  assertEquals(response.status, 500);
  assertEquals(sent, []);
  assert(logs.every((line) => !line.includes(ADDRESS)));
});

Deno.test("reads the database's answer", () => {
  assertEquals(
    reservationFromRow({
      outcome: "send",
      send_id: 41,
      code: "THEAN-7KQ4-M9XP",
      first_name: "Gran",
      inviter: "Alice",
      household: "The Andersons",
      expires_at: "2026-11-18T15:00:00Z",
      time_zone: "America/Chicago",
    }),
    reserved,
  );
  assertEquals(reservationFromRow({ outcome: "send", send_id: 1, code: "C", first_name: "G", household: "H",
    expires_at: "2026-11-18T15:00:00Z", inviter: null, time_zone: null }).outcome, "send");
  assertEquals(reservationFromRow({ outcome: "kid" }), { outcome: "kid" });
  assertThrows(() => reservationFromRow({ outcome: "toString" }));
  assertThrows(() => reservationFromRow(null));
});

Deno.test("the subject is fixed: nothing the family typed reaches it", () => {
  for (const names of [reserved, { ...reserved, inviter: "Bank of X: verify now", household: "Act now\r\nBcc: x" }]) {
    assertEquals(inviteEmail(names).subject, INVITE_SUBJECT);
  }
  assertEquals(INVITE_SUBJECT, "You're invited to join a family on Foon");
});

Deno.test("names show only as labeled plain text", () => {
  const email = inviteEmail(reserved);
  for (const line of ["Invited by: Alice", "Family: The Andersons", "Invite for: Gran"]) {
    assertStringIncludes(email.text, line);
  }
  assertStringIncludes(email.html, "<li>Invited by: Alice</li>");
});

Deno.test("names that look like a link or an address are never shown", () => {
  for (const name of [
    "https://evil.example",
    "Visit evil.com now",
    "www.evil",
    "hxxp://x",
    "javascript://x",
    "bob@evil.co",
    "Claim at paypal.com-secure.ru",
    "Ünïcode.Domäin",
    "Call 1 800 555 0100 re your refund",
    "Text (216) 555-0100",
    "+44 20 7946 0958",
    "Go to paypal dot com",
    "Call １８００５５５０１００",
    "paypal．com",
    "evil。com",
    "paypal [dot] com",
    "paypal . com",
    "paypal. com",
    "Call 1-800-FLOWERS 555",
    "Smiths 🎉 click here: evil",
  ]) {
    assertEquals(plainName(name), "(not shown)", name);
  }
  for (const name of ["The Andersons", "St. Clair", "Mary-Jo", "O'Brien family", "Mr. Smith", "The 3 Smiths", "Apt 1012 crew", "Dot Cotton", "José & Zoë", "Nguyễn", "Smith, Jr."]) {
    assertEquals(plainName(name), name, name);
  }
});

Deno.test("the only link is our own invite link", () => {
  const email = inviteEmail({ ...reserved, inviter: "see evil.com", household: "https://phish.example/login" });
  const links = [...email.text.matchAll(/https?:\/\/\S+/g)].map((match) => match[0]);
  assertEquals(links, ["https://www.getfoon.com/invite?code=THEAN-7KQ4-M9XP"]);
  assert(!email.html.includes("evil.com") && !email.html.includes("phish.example"));
  assert(!email.html.includes("<a "), "no anchors at all: mail apps link our URL themselves");
});

Deno.test("names the family typed can't break the HTML, and are trimmed", () => {
  const email = inviteEmail({ ...reserved, inviter: "Al\r\nice", household: "Smith & O'Neil" });
  assertStringIncludes(email.html, "Smith &amp; O&#39;Neil");
  const tagged = inviteEmail({ ...reserved, household: "<b>Smiths</b>" });
  assertEquals(tagged.html.includes("<b>"), false);
  assertStringIncludes(tagged.text, "Family: (not shown)");
  assertStringIncludes(email.text, "Invited by: Al ice");
  assertEquals(plainName("  "), "(not shown)");
  assertEquals(plainName(null), "(not shown)");
  assertEquals(plainName("x".repeat(80)).length, 60);
});

Deno.test("with no inviter name or a bad date, it still reads", () => {
  const email = inviteEmail({ ...reserved, inviter: null, expiresAt: "not a date" });
  assertStringIncludes(email.text, "Invited by: (not shown)");
  assertStringIncludes(email.text, "expires 7 days after it was made");
});

Deno.test("every limit (3 per invite, a new household, 5 per parent, 10 per household) refuses alike, sends nothing", async () => {
  // reserve_invite_email answers rate_limited for each limit, never saying which (pgTAP 95_invite_email checks each).
  const { deps, sent } = fakeDeps({ outcome: "rate_limited" });
  const response = await handleInviteEmail(ask(good), deps);
  assertEquals(response.status, 429);
  assertEquals(await response.json(), { error: "rate_limited" });
  assertEquals(sent, []);
});

Deno.test("the link matches the app's universal link", () => {
  assertEquals(inviteLink("THEAN-7KQ4-M9XP"), "https://www.getfoon.com/invite?code=THEAN-7KQ4-M9XP");
});
