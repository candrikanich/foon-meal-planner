import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { type Email, resendConfigFromEnv, sendEmail } from "../_shared/resend.ts";
import { newToken, sha256 } from "../_shared/token.ts";
import { confirmationEmail, noticeEmail, PRIVACY_URL, TEXT_VERSION } from "./email.ts";
import {
  type ConsentDeps,
  type DecideResult,
  handleParentalConsent,
  RefusedError,
  type RequestResult,
} from "./handler.ts";

const fn = "https://x.supabase.co/functions/v1/parental-consent";
const memberId = "11111111-2222-3333-4444-555555555555";
const requestId = "99999999-2222-3333-4444-555555555555";
const token = "t".repeat(43);
const send: RequestResult = {
  outcome: "send",
  requestId,
  sendId: 7,
  email: "parent@example.com",
  emailSource: "account",
  firstName: "Nora",
};
const agreed: DecideResult = {
  outcome: "send_confirmation",
  requestId,
  email: "parent@example.com",
  firstName: "Nora",
  decidedAt: "2026-11-08T15:04:00Z",
};

function fakeDeps(overrides: Partial<ConsentDeps> = {}) {
  const calls: string[] = [];
  const emails: Email[] = [];
  const logs: string[] = [];
  const deps: ConsentDeps = {
    allowedOrigins: ["https://getfoon.com"],
    siteUrl: "https://getfoon.com",
    functionUrl: fn,
    userFromToken: (jwt) => Promise.resolve(jwt === "good" ? "user-1" : null),
    request: (_jwt, input) => {
      calls.push(`request ${input.memberId} ${input.email}`);
      return Promise.resolve(send);
    },
    markSent: (input) => {
      calls.push(`markSent ${input.requestId} ${input.sendId} ${input.textVersion}`);
      return Promise.resolve(true);
    },
    releaseSend: (input) => {
      calls.push(`releaseSend ${input.requestId} ${input.sendId}`);
      return Promise.resolve();
    },
    lookup: () => Promise.resolve({ outcome: "pending", firstName: "Nora", expiresAt: "2026-11-15T00:00:00Z" }),
    decide: (_hash, decision) => {
      calls.push(`decide ${decision}`);
      return Promise.resolve(decision === "agree" ? agreed : { outcome: "refused" });
    },
    releaseConfirmation: (id) => {
      calls.push(`releaseConfirmation ${id}`);
      return Promise.resolve();
    },
    activate: (id) => {
      calls.push(`activate ${id}`);
      return Promise.resolve("confirmed");
    },
    withdrawLookup: () => Promise.resolve({ outcome: "active", firstName: "Nora" }),
    withdraw: () => {
      calls.push("withdraw");
      return Promise.resolve("withdrawn");
    },
    newToken: () => token,
    sha256,
    sendEmail: (email) => {
      emails.push(email);
      return Promise.resolve("sent");
    },
    log: (message, error) => logs.push(`${message} ${error instanceof Error ? error.message : error ?? ""}`),
    ...overrides,
  };
  return { deps, calls, emails, logs };
}

const fromApp = (body: unknown, jwt: string | null = "good") =>
  new Request(fn, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}) },
    body: JSON.stringify(body),
  });

const fromSite = (query: string, body: unknown, origin = "https://getfoon.com") =>
  new Request(`${fn}${query}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: origin },
    body: JSON.stringify(body),
  });

Deno.test("opening an emailed link changes nothing: it only redirects to the site's page", async () => {
  const { deps, calls } = fakeDeps();
  const consent = await handleParentalConsent(new Request(`${fn}?consent=${token}`), deps);
  assertEquals(consent.status, 303);
  assertEquals(consent.headers.get("Location"), `https://getfoon.com/consent?t=${token}`);
  const withdraw = await handleParentalConsent(new Request(`${fn}?withdraw=${token}`), deps);
  assertEquals(withdraw.headers.get("Location"), `https://getfoon.com/consent/withdraw?t=${token}`);
  const broken = await handleParentalConsent(new Request(`${fn}?consent=<x>`), deps);
  assertEquals(broken.headers.get("Location"), "https://getfoon.com/consent/expired");
  const brokenWithdraw = await handleParentalConsent(new Request(`${fn}?withdraw=x`), deps);
  assertEquals(brokenWithdraw.headers.get("Location"), "https://getfoon.com/consent/expired?link=withdraw");
  assertEquals(calls, []);
});

Deno.test("the app's request needs a signed-in user", async () => {
  const { deps, calls } = fakeDeps();
  assertEquals((await handleParentalConsent(fromApp({ memberId }, null), deps)).status, 401);
  assertEquals((await handleParentalConsent(fromApp({ memberId }, "bad"), deps)).status, 401);
  assertEquals(calls, []);
});

Deno.test("a request emails the notice, then records its token and wording", async () => {
  const { deps, calls, emails } = fakeDeps();
  const response = await handleParentalConsent(fromApp({ memberId }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    result: "sent",
    requestId,
    email: "parent@example.com",
    emailSource: "account",
  });
  assertEquals(calls, [`request ${memberId} null`, `markSent ${requestId} 7 ${TEXT_VERSION}`]);
  assertEquals(emails[0].to, "parent@example.com");
  assertStringIncludes(emails[0].text, `${fn}?consent=${token}`);
  assertEquals(TEXT_VERSION, "parental-invite-v3");
});

Deno.test("a notice whose request changed meanwhile isn't reported as sent", async () => {
  const { deps, logs } = fakeDeps({ markSent: () => Promise.resolve(false) });
  const response = await handleParentalConsent(fromApp({ memberId }), deps);
  assertEquals([response.status, await response.json()], [500, { error: "try_again" }]);
  assert(logs.some((line) => line.includes("no longer pending")));
});

Deno.test("a typed address is checked and passed on", async () => {
  const { deps, calls } = fakeDeps();
  const bad = await handleParentalConsent(fromApp({ memberId, email: "nope" }), deps);
  assertEquals([bad.status, await bad.json()], [400, { error: "bad_email" }]);
  await handleParentalConsent(fromApp({ memberId, email: " pat@example.com " }), deps);
  assertEquals(calls[0], `request ${memberId} pat@example.com`);
  const badMember = await handleParentalConsent(fromApp({ memberId: "x" }), deps);
  assertEquals([badMember.status, await badMember.json()], [400, { error: "bad_request" }]);
});

Deno.test("each database answer has its own response", async () => {
  const cases: Array<[RequestResult | RefusedError, number, Record<string, string>]> = [
    [{ outcome: "already_consented" }, 200, { result: "already_consented" }],
    [{ outcome: "no_email" }, 200, { result: "no_email" }],
    [{ outcome: "rate_limited" }, 429, { error: "rate_limited", message: "Try again in a little while." }],
    [new RefusedError("42501"), 403, { error: "not_a_parent" }],
    [new RefusedError("22023"), 409, { error: "not_eligible" }],
    [new RefusedError("22000"), 400, { error: "bad_email" }],
  ];
  for (const [answer, status, body] of cases) {
    const { deps, emails } = fakeDeps({
      request: () => answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer),
    });
    const response = await handleParentalConsent(fromApp({ memberId }), deps);
    assertEquals([response.status, await response.json()], [status, body]);
    assertEquals(emails, []);
  }
});

Deno.test("a notice that doesn't go out releases its reservation and records no token", async () => {
  const failing = fakeDeps({ sendEmail: () => Promise.reject(new Error("Resend answered 500")) });
  const response = await handleParentalConsent(fromApp({ memberId }), failing.deps);
  assertEquals([response.status, await response.json()], [502, { error: "send_failed" }]);
  assertEquals(failing.calls, [`request ${memberId} null`, `releaseSend ${requestId} 7`]);

  const off = fakeDeps({ sendEmail: () => Promise.resolve("off") });
  const offResponse = await handleParentalConsent(fromApp({ memberId }), off.deps);
  assertEquals([offResponse.status, await offResponse.json()], [503, { error: "email_off" }]);
  assertEquals(off.calls.at(-1), `releaseSend ${requestId} 7`);
});

Deno.test("the site's lookup changes nothing and says whom the link is for", async () => {
  const { deps, calls } = fakeDeps();
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "lookup" }), deps);
  assertEquals(await response.json(), { result: "pending", firstName: "Nora", expiresAt: "2026-11-15T00:00:00Z" });
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://getfoon.com");
  assertEquals(calls, []);
  const invalid = await handleParentalConsent(fromSite("?consent=short", { decision: "lookup" }), deps);
  assertEquals(await invalid.json(), { result: "invalid" });
  const badBody = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "maybe" }), deps);
  assertEquals(badBody.status, 400);
});

Deno.test("I agree sends email 2 and only then activates the consent", async () => {
  const { deps, calls, emails } = fakeDeps();
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
  assertEquals(await response.json(), { result: "confirmed" });
  assertEquals(calls, ["decide agree", `activate ${requestId}`]);
  assertEquals(emails[0].subject, "You agreed Nora can use Foon");
  assertStringIncludes(emails[0].text, `${fn}?withdraw=${token}`);
});

Deno.test("if email 2 fails nothing is activated, the agreement waits, and tapping again works", async () => {
  let fail = true;
  const { deps, calls } = fakeDeps({
    sendEmail: () => fail ? Promise.reject(new Error("Resend answered 503")) : Promise.resolve("sent"),
  });
  const first = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
  assertEquals(await first.json(), { result: "try_again" });
  assertEquals(calls, ["decide agree", `releaseConfirmation ${requestId}`]);
  fail = false;
  const second = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
  assertEquals(await second.json(), { result: "confirmed" });
  assertEquals(calls.slice(2), ["decide agree", `activate ${requestId}`]);
});

Deno.test("if activation fails after email 2, the reservation is released for a retry", async () => {
  const { deps, calls } = fakeDeps({ activate: () => Promise.reject(new Error("db down")) });
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
  assertEquals(await response.json(), { result: "try_again" });
  assertEquals(calls.at(-1), `releaseConfirmation ${requestId}`);
});

Deno.test("refusing, a used link and a send in progress each answer plainly", async () => {
  const { deps, emails } = fakeDeps();
  const refused = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "refuse" }), deps);
  assertEquals(await refused.json(), { result: "refused" });
  assertEquals(emails, []);
  for (const outcome of ["confirmed", "expired", "invalid"] as const) {
    const { deps } = fakeDeps({ decide: () => Promise.resolve({ outcome }) });
    const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
    assertEquals(await response.json(), { result: outcome });
  }
  const busy = fakeDeps({ decide: () => Promise.resolve({ outcome: "busy" }) });
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), busy.deps);
  assertEquals(await response.json(), { result: "try_again" });
});

Deno.test("the withdraw page looks up, then withdraws", async () => {
  const { deps, calls } = fakeDeps();
  const lookup = await handleParentalConsent(fromSite(`?withdraw=${token}`, { decision: "lookup" }), deps);
  assertEquals(await lookup.json(), { result: "active", firstName: "Nora" });
  assertEquals(calls, []);
  const done = await handleParentalConsent(fromSite(`?withdraw=${token}`, { decision: "withdraw" }), deps);
  assertEquals(await done.json(), { result: "withdrawn" });
  assertEquals(calls, ["withdraw"]);
  const wrong = await handleParentalConsent(fromSite(`?withdraw=${token}`, { decision: "agree" }), deps);
  assertEquals(wrong.status, 400);
});

Deno.test("other sites can't post, and a preflight from ours is answered", async () => {
  const { deps, calls } = fakeDeps();
  const evil = await handleParentalConsent(
    fromSite(`?consent=${token}`, { decision: "agree" }, "https://evil.example"),
    deps,
  );
  assertEquals(evil.status, 403);
  const preflight = await handleParentalConsent(
    new Request(`${fn}?consent=${token}`, { method: "OPTIONS", headers: { Origin: "https://getfoon.com" } }),
    deps,
  );
  assertEquals(preflight.status, 204);
  assertEquals(preflight.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
  assertEquals((await handleParentalConsent(new Request(fn), deps)).status, 404);
  assertEquals(calls, []);
});

Deno.test("logs never hold an email address, a name or a token", async () => {
  const runs = [
    fakeDeps({ sendEmail: () => Promise.reject(new Error("Resend answered 500")) }),
    fakeDeps({ sendEmail: () => Promise.resolve("off") }),
    fakeDeps({ markSent: () => Promise.reject(new Error("db down")) }),
    fakeDeps({ markSent: () => Promise.resolve(false) }),
    fakeDeps({ activate: () => Promise.resolve("expired") }),
  ];
  for (const { deps } of runs) {
    await handleParentalConsent(fromApp({ memberId, email: "typed@example.com" }), deps);
    await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
  }
  const logs = runs.flatMap((run) => run.logs);
  assert(logs.length > 0);
  for (const line of logs) {
    assert(!line.includes("@"), line);
    assert(!line.includes("Nora"), line);
    assert(!line.includes(token), line);
  }
});

Deno.test("email 1 is the direct notice: every 312.4(c)(1) element", () => {
  const { subject, text, html } = noticeEmail({
    firstName: "Nora",
    consentUrl: `${fn}?consent=${token}`,
    emailSource: "account",
  });
  assertEquals(subject, "Confirm Nora can use Foon");
  for (const body of [text, html]) {
    assertStringIncludes(body, "You asked to invite Nora"); // (i) why the parent is getting it
    assertStringIncludes(body, "We haven't collected anything from Nora");
    assertStringIncludes(body, "Foon collects nothing from Nora, no invite can be made"); // (ii) consent needed
    assertStringIncludes(body, "first name, avatar, allergies and schedule"); // (iii) what's collected
    assertStringIncludes(body, "Apple sign-in (account ID and email) and a notification token");
    assertStringIncludes(body, "We don't disclose it to"); // (iv) no disclosure
    assertStringIncludes(body, "never sold or used for ads");
    assertStringIncludes(body, PRIVACY_URL); // (v) the online notice
    assertStringIncludes(body, "Review and agree"); // (vi) how to consent
    assertStringIncludes(body, "This link works for 7 days"); // (vii) the request lapses
    assertStringIncludes(body, "withdraw your consent at any time"); // and how to withdraw, up front
    assertStringIncludes(body, "34125 Center Ridge Road #1012"); // who sent it
    assertStringIncludes(body, "don't copy it anywhere else");
  }
  assertStringIncludes(text, `Review and agree: ${fn}?consent=${token}`);
  assertStringIncludes(html, `href="${fn}?consent=${token}"`);
  const typed = noticeEmail({ firstName: "Nora", consentUrl: "u", emailSource: "typed" });
  assertStringIncludes(typed.text, "We used the email you typed in Foon.");
  assertStringIncludes(typed.text, "delete it once that one is sent or this request ends");
});

Deno.test("email 2 confirms the consent and says how to withdraw it, by link and in the app", () => {
  const { subject, text, html } = confirmationEmail({
    firstName: "Nora",
    withdrawUrl: `${fn}?withdraw=${token}`,
    agreedAt: "2026-11-08T15:04:00Z",
  });
  assertEquals(subject, "You agreed Nora can use Foon");
  for (const body of [text, html]) {
    assertStringIncludes(body, "November 8, 2026 at 3:04");
    assertStringIncludes(body, "Withdraw consent");
    assertStringIncludes(body, "this link works for 30 days");
    assertStringIncludes(body, "open Family, then Nora, then Withdraw consent");
    assertStringIncludes(body, "If this wasn't you, withdraw now.");
    assertStringIncludes(body, PRIVACY_URL);
  }
  assertStringIncludes(text, `Withdraw consent: ${fn}?withdraw=${token}`);
  assertStringIncludes(html, `href="${fn}?withdraw=${token}"`);
});

Deno.test("the kid's first name is escaped in the HTML", () => {
  const name = `<b>Al</b> & "Jo's"`;
  const notice = noticeEmail({ firstName: name, consentUrl: "u", emailSource: "account" });
  const confirmation = confirmationEmail({ firstName: name, withdrawUrl: "w", agreedAt: "2026-11-08T15:04:00Z" });
  for (const html of [notice.html, confirmation.html]) {
    assert(!html.includes("<b>Al</b>"));
    assertStringIncludes(html, "&lt;b&gt;Al&lt;/b&gt; &amp; &quot;Jo&#39;s&quot;");
  }
});

Deno.test("shared helpers: tokens are hashed, and Resend gets the key and the sender", async () => {
  assertEquals(newToken().length, 43);
  assertEquals((await sha256("abc")).slice(0, 8), "ba7816bf");
  assertEquals(resendConfigFromEnv((key) => ({ RESEND_API_KEY: "k" })[key], "CONSENT_FROM"), null);
  const config = resendConfigFromEnv(
    (key) => ({ RESEND_API_KEY: "k", CONSENT_FROM: "Foon <info@getfoon.com>" })[key],
    "CONSENT_FROM",
  )!;
  let seen: { auth: string | null; from: string; to: string[]; headers?: unknown } | undefined;
  const fake = ((_url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string);
    seen = {
      auth: new Headers(init.headers).get("Authorization"),
      from: body.from,
      to: body.to,
      headers: body.headers,
    };
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as unknown as typeof fetch;
  await sendEmail(config, { to: "a@example.com", subject: "s", text: "t", html: "h" }, fake);
  assertEquals(seen, { auth: "Bearer k", from: "Foon <info@getfoon.com>", to: ["a@example.com"], headers: undefined });
  const failing = (() => Promise.resolve(new Response("{}", { status: 422 }))) as unknown as typeof fetch;
  let message = "";
  await sendEmail(config, { to: "a@example.com", subject: "s", text: "t", html: "h" }, failing).catch((error) =>
    message = error.message
  );
  assertEquals(message, "Resend answered 422");
});
