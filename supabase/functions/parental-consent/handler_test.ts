import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { type Email, resendConfigFromEnv, SEND_TIMEOUT_MS, sendEmail } from "../_shared/resend.ts";
import { newToken, sha256 } from "../_shared/token.ts";
import { confirmationEmail, noticeEmail, PRIVACY_URL, TEXT_VERSION } from "./email.ts";
import {
  type ConsentDeps,
  consentOrigins,
  type DecideResult,
  handleParentalConsent,
  RefusedError,
  RENEWAL_BATCH,
  RENEWAL_BUDGET_MS,
  type RenewalClaim,
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
  reason: "invite",
};
const cronSecret = "s".repeat(40);
const claim = (overrides: Partial<RenewalClaim> = {}): RenewalClaim => ({
  requestId,
  sendId: 8,
  email: "parent@example.com",
  firstName: "Nora",
  reminder: false,
  summary: "Foon now confirms a parent's consent by email.",
  agreedAt: "2026-10-01T12:00:00Z",
  wasLinked: true,
  ...overrides,
});
const agreed: DecideResult = {
  outcome: "send_confirmation",
  requestId,
  email: "parent@example.com",
  firstName: "Nora",
  decidedAt: "2026-11-08T15:04:00Z",
  reason: "invite",
};

// parental_wording_ok as the database applies it: a registered parental wording, at or after the one in force (every
// version here requires agreeing again). Null: nothing in force.
const ordinals: Record<string, number> = {
  "parental-invite-v1": 1,
  "parental-invite-v2": 2,
  "parental-invite-v3": 3,
  "parental-invite-v4": 4,
};
const satisfies = (inForce: string | null) => (wording: string) =>
  wording in ordinals && (inForce === null || ordinals[wording] >= ordinals[inForce]);

function fakeDeps(overrides: Partial<ConsentDeps> = {}, inForce: string | null = null) {
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
    cronSecret,
    claimRenewals: (batchSize, wording) => {
      if (!satisfies(inForce)(wording)) return Promise.reject(new RefusedError("22023"));
      calls.push(`claimRenewals ${batchSize} ${wording}`);
      return Promise.resolve([]);
    },
    wordingOk: (wording) => Promise.resolve(satisfies(inForce)(wording)),
    now: () => 0,
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
    [new RefusedError("28000"), 401, { error: "not_signed_in" }],
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

Deno.test("a link whose kid already has consent, or whose consent was withdrawn, says so", async () => {
  for (const outcome of ["already_consented", "withdrawn"] as const) {
    const { deps, emails, calls } = fakeDeps({
      lookup: () => Promise.resolve({ outcome }),
      decide: () => Promise.resolve({ outcome }),
    });
    const lookup = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "lookup" }), deps);
    assertEquals(await lookup.json(), { result: outcome });
    const agree = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
    assertEquals(await agree.json(), { result: outcome });
    assertEquals(emails, []);
    assert(!calls.some((call) => call.startsWith("activate")));
  }
  const raced = fakeDeps({ activate: () => Promise.resolve("already_consented") });
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), raced.deps);
  assertEquals(await response.json(), { result: "already_consented" });
});

Deno.test("a preview's site URL is allowed by its origin only", () => {
  assertEquals(consentOrigins(undefined).length, 5);
  assertEquals(consentOrigins("https://getfoon.com").length, 5);
  assertEquals(consentOrigins("https://foon-git-x.vercel.app/some/path").at(-1), "https://foon-git-x.vercel.app");
  assertEquals(consentOrigins("not a url").length, 5);
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

const fromCron = (secret: string | null, method = "POST") =>
  new Request(`${fn}?renewals=1`, {
    method,
    headers: { "Content-Type": "application/json", ...(secret === null ? {} : { "x-consent-cron-secret": secret }) },
    body: method === "POST" ? "{}" : undefined,
  });

Deno.test("renewal mode refuses a missing or wrong secret, and refuses everyone while none is set", async () => {
  const { deps, calls } = fakeDeps();
  for (const secret of [null, "", "wrong", cronSecret.slice(1), `${cronSecret}x`]) {
    const response = await handleParentalConsent(fromCron(secret), deps);
    assertEquals([response.status, await response.json()], [401, { error: "unauthorized" }]);
  }
  const unset = fakeDeps({ cronSecret: undefined });
  assertEquals((await handleParentalConsent(fromCron(cronSecret), unset.deps)).status, 401);
  const blank = fakeDeps({ cronSecret: "" });
  assertEquals((await handleParentalConsent(fromCron(""), blank.deps)).status, 401);
  assertEquals((await handleParentalConsent(fromCron(cronSecret, "GET"), deps)).status, 404);
  assertEquals([...calls, ...unset.calls, ...blank.calls], []);
});

// A claim that, like the database, refuses a wording parental_wording_ok wouldn't pass, then hands out `claims`.
const claiming = (claims: RenewalClaim[], calls: string[] = [], inForce: string | null = null) =>
(batchSize: number, wording: string) => {
  if (!satisfies(inForce)(wording)) return Promise.reject(new RefusedError("22023"));
  calls.push(`claimRenewals ${batchSize} ${wording}`);
  return Promise.resolve(claims);
};
const twoParents = [claim(), claim({ requestId: "r2", sendId: 9, email: "other@example.com" })];

Deno.test("renewal mode with the secret claims a batch in its wording, emails each parent, then records it", async () => {
  const run = fakeDeps();
  run.deps.claimRenewals = claiming(twoParents, run.calls);
  const response = await handleParentalConsent(fromCron(cronSecret), run.deps);
  assertEquals([response.status, await response.json()], [200, { sent: 2, failed: 0, unrecorded: 0, deferred: 0 }]);
  assertEquals(run.calls, [
    `claimRenewals ${RENEWAL_BATCH} ${TEXT_VERSION}`,
    `markSent ${requestId} 8 ${TEXT_VERSION}`,
    `markSent r2 9 ${TEXT_VERSION}`,
  ]);
  assertEquals(run.emails.map((email) => [email.to, email.subject]), [
    ["parent@example.com", "Can Nora keep using Foon?"],
    ["other@example.com", "Can Nora keep using Foon?"],
  ]);
  assertStringIncludes(run.emails[0].text, `Review and agree: ${fn}?consent=${token}`);
  assertStringIncludes(run.emails[0].text, "What changed: Foon now confirms a parent's consent by email.");
  assertStringIncludes(run.emails[0].text, "agreed on October 1, 2026");
});

Deno.test("renewal mode with nothing owed sends nothing", async () => {
  const { deps, calls, emails } = fakeDeps();
  const response = await handleParentalConsent(fromCron(cronSecret), deps);
  assertEquals([response.status, await response.json()], [200, { sent: 0, failed: 0, unrecorded: 0, deferred: 0 }]);
  assertEquals(calls, [`claimRenewals ${RENEWAL_BATCH} ${TEXT_VERSION}`]);
  assertEquals(emails, []);
});

Deno.test("the reminder is the same email, saying it's a reminder", async () => {
  const { deps, emails } = fakeDeps({ claimRenewals: claiming([claim({ reminder: true })]) });
  await handleParentalConsent(fromCron(cronSecret), deps);
  assertEquals(emails[0].subject, "Reminder: Can Nora keep using Foon?");
  assertStringIncludes(emails[0].text, "A reminder: we emailed your family about this a week ago");
});

Deno.test("renewals go out while this function's wording satisfies the one in force, even ahead of it", async () => {
  // TEXT_VERSION is v3: in force v2 (deployed ahead) or v3 (current) both send.
  for (const inForce of [null, "parental-invite-v2", TEXT_VERSION]) {
    const run = fakeDeps({}, inForce);
    run.deps.claimRenewals = claiming([claim()], run.calls, inForce);
    const response = await handleParentalConsent(fromCron(cronSecret), run.deps);
    assertEquals(response.status, 200, `in force: ${inForce}`);
    assertEquals(run.emails.length, 1);
  }
});

Deno.test("with outdated wording, the claim reserves nothing, nothing is sent, and the run answers 503", async () => {
  const run = fakeDeps({}, "parental-invite-v4");
  run.deps.claimRenewals = claiming(twoParents, run.calls, "parental-invite-v4");
  const response = await handleParentalConsent(fromCron(cronSecret), run.deps);
  assertEquals([response.status, await response.json()], [503, { error: "wording_outdated" }]);
  assertEquals([run.calls, run.emails], [[], []]);
  assert(run.logs.some((line) => line.includes(TEXT_VERSION) && line.includes("nothing sent")));
});

Deno.test("a renewal email that fails is released, and the rest still go", async () => {
  let first = true;
  const { deps, calls } = fakeDeps({
    claimRenewals: claiming(twoParents),
    sendEmail: () => {
      if (!first) return Promise.resolve("sent");
      first = false;
      return Promise.reject(new Error("Resend didn't answer in 10000 ms"));
    },
  });
  const response = await handleParentalConsent(fromCron(cronSecret), deps);
  assertEquals([response.status, await response.json()], [200, { sent: 1, failed: 1, unrecorded: 0, deferred: 0 }]);
  assertEquals(calls, [`releaseSend ${requestId} 8`, `markSent r2 9 ${TEXT_VERSION}`]);
});

Deno.test("a release that fails inside the run is logged, and the rest still go", async () => {
  let first = true;
  const { deps, calls, logs } = fakeDeps({
    claimRenewals: claiming(twoParents),
    releaseSend: () => Promise.reject(new Error("db down")),
    sendEmail: () => {
      if (!first) return Promise.resolve("sent");
      first = false;
      return Promise.reject(new Error("Resend answered 500"));
    },
  });
  const response = await handleParentalConsent(fromCron(cronSecret), deps);
  assertEquals([response.status, await response.json()], [200, { sent: 1, failed: 1, unrecorded: 0, deferred: 0 }]);
  assertEquals(calls, [`markSent r2 9 ${TEXT_VERSION}`]);
  assert(logs.some((line) => line.includes("could not release send 8")));
});

Deno.test("a renewal sent but not recorded, or whose recording throws, is counted, and the rest still go", async () => {
  const notPending = fakeDeps({ claimRenewals: claiming([claim()]), markSent: () => Promise.resolve(false) });
  const response = await handleParentalConsent(fromCron(cronSecret), notPending.deps);
  assertEquals(await response.json(), { sent: 0, failed: 0, unrecorded: 1, deferred: 0 });

  let first = true;
  const throwing = fakeDeps({
    claimRenewals: claiming(twoParents),
    markSent: () => {
      if (!first) return Promise.resolve(true);
      first = false;
      return Promise.reject(new Error("db down"));
    },
  });
  const thrown = await handleParentalConsent(fromCron(cronSecret), throwing.deps);
  assertEquals([thrown.status, await thrown.json()], [200, { sent: 1, failed: 0, unrecorded: 1, deferred: 0 }]);
  assertEquals(throwing.emails.length, 2);
  assert(throwing.logs.some((line) => line.includes("sent but not recorded")));

  const broken = fakeDeps({ claimRenewals: () => Promise.reject(new Error("db down")) });
  assertEquals((await handleParentalConsent(fromCron(cronSecret), broken.deps)).status, 500);
});

Deno.test("with email off, every claimed renewal is released and the run answers 503", async () => {
  const { deps, calls } = fakeDeps({ claimRenewals: claiming(twoParents), sendEmail: () => Promise.resolve("off") });
  const response = await handleParentalConsent(fromCron(cronSecret), deps);
  assertEquals([response.status, await response.json()], [503, {
    error: "email_off",
    sent: 0,
    failed: 2,
    unrecorded: 0,
    deferred: 0,
  }]);
  assertEquals(calls, [`releaseSend ${requestId} 8`, "releaseSend r2 9"]);
});

Deno.test("past its time budget, the run releases every claim it hasn't reached", async () => {
  let clock = 0;
  const { deps, calls, emails, logs } = fakeDeps({
    claimRenewals: claiming([claim(), claim({ requestId: "r2", sendId: 9 }), claim({ requestId: "r3", sendId: 10 })]),
    now: () => clock,
    sendEmail: (email) => {
      clock += RENEWAL_BUDGET_MS; // one slow send uses up the run
      emails.push(email);
      return Promise.resolve("sent");
    },
  });
  const response = await handleParentalConsent(fromCron(cronSecret), deps);
  assertEquals([response.status, await response.json()], [200, { sent: 1, failed: 0, unrecorded: 0, deferred: 2 }]);
  assertEquals(calls, [`markSent ${requestId} 8 ${TEXT_VERSION}`, "releaseSend r2 9", "releaseSend r3 10"]);
  assertEquals(emails.length, 1);
  assert(logs.some((line) => line.includes("ran out of time")));
});

Deno.test("the app's request sends only while this function's wording satisfies the one in force", async () => {
  for (const inForce of [null, "parental-invite-v2", TEXT_VERSION]) {
    const ok = fakeDeps({}, inForce);
    assertEquals((await handleParentalConsent(fromApp({ memberId }), ok.deps)).status, 200, `in force: ${inForce}`);
  }
  const { deps, calls, emails } = fakeDeps({}, "parental-invite-v4");
  const response = await handleParentalConsent(fromApp({ memberId }), deps);
  assertEquals([response.status, await response.json()], [503, { error: "wording_outdated" }]);
  assertEquals(calls, [`request ${memberId} null`, `releaseSend ${requestId} 7`]);
  assertEquals(emails, []);
  const unchecked = fakeDeps({ wordingOk: () => Promise.reject(new Error("db down")) });
  const failed = await handleParentalConsent(fromApp({ memberId }), unchecked.deps);
  assertEquals([failed.status, unchecked.calls.at(-1), unchecked.emails], [500, `releaseSend ${requestId} 7`, []]);
});

Deno.test("the app's renewal request asks in this function's wording and emails what the cron's does", async () => {
  const wordings: string[] = [];
  const { deps, emails } = fakeDeps({
    request: (_jwt, input) => {
      wordings.push(input.wording);
      return Promise.resolve({
        ...send,
        reason: "renewal",
        renewal: {
          summary: "Foon now confirms a parent's consent by email.",
          agreedBefore: "2026-10-01T12:00:00Z",
          held: true,
          wasLinked: true,
        },
      } as RequestResult);
    },
  });
  const response = await handleParentalConsent(fromApp({ memberId }), deps);
  assertEquals(response.status, 200);
  assertEquals(wordings, [TEXT_VERSION]);
  assertEquals(emails[0].subject, "Can Nora keep using Foon?");
  assertStringIncludes(emails[0].text, "What changed: Foon now confirms a parent's consent by email.");
  assertStringIncludes(emails[0].text, "agreed on October 1, 2026");
  assertStringIncludes(emails[0].text, "Until a parent agrees, Nora is signed out of Foon.");
});

Deno.test("a renewal the app asks for before the hold opens says the kid will be signed out", async () => {
  const { deps, emails } = fakeDeps({
    request: () =>
      Promise.resolve({
        ...send,
        reason: "renewal",
        renewal: { summary: null, agreedBefore: null, held: false, wasLinked: true },
      } as RequestResult),
  });
  assertEquals((await handleParentalConsent(fromApp({ memberId }), deps)).status, 200);
  assertStringIncludes(emails[0].text, "Until a parent agrees, Nora will be signed out of Foon soon.");
});

Deno.test("renewal emails for a kid who never signed in never say signed out, from the app or the cron", async () => {
  const app = fakeDeps({
    request: () =>
      Promise.resolve({
        ...send,
        reason: "renewal",
        renewal: { summary: null, agreedBefore: null, held: true, wasLinked: false },
      } as RequestResult),
  });
  assertEquals((await handleParentalConsent(fromApp({ memberId }), app.deps)).status, 200);
  assert(!app.emails[0].text.includes("signed out"));

  const cron = fakeDeps({ claimRenewals: () => Promise.resolve([claim({ wasLinked: false })]) }, "parental-invite-v3");
  assertEquals((await handleParentalConsent(fromCron(cronSecret), cron.deps)).status, 200);
  assert(!cron.emails[0].text.includes("signed out"));
  assertStringIncludes(cron.emails[0].text, "Until a parent agrees, Nora can't use Foon on their own device.");
});

Deno.test("an older database's renewal answer, without the renewal fields, still sends a whole notice", async () => {
  const { deps, emails } = fakeDeps({
    request: () => Promise.resolve({ ...send, reason: "renewal" } as RequestResult),
  });
  const response = await handleParentalConsent(fromApp({ memberId }), deps);
  assertEquals(response.status, 200);
  assertEquals(emails[0].subject, "Can Nora keep using Foon?");
  assert(!emails[0].text.includes("What changed"));
  assertStringIncludes(emails[0].text, "Until a parent agrees, Nora is signed out of Foon.");
});

Deno.test("I agree after a renewal confirms that the kid is back in, not that they can be invited", async () => {
  const { deps, emails } = fakeDeps({
    decide: () => Promise.resolve({ ...agreed, reason: "renewal" } as DecideResult),
  });
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "agree" }), deps);
  assertEquals(await response.json(), { result: "confirmed" });
  assertStringIncludes(emails[0].text, "Nora can use Foon again.");
  assert(!emails[0].text.includes("You can invite Nora now"));
});

Deno.test("a renewal link's lookup passes on what changed and when a parent agreed", async () => {
  const { deps } = fakeDeps({
    lookup: () =>
      Promise.resolve({
        outcome: "pending",
        firstName: "Nora",
        expiresAt: "2026-11-15T00:00:00Z",
        renewal: { summary: "What changed.", agreedBefore: "2026-10-01T12:00:00Z" },
      }),
  });
  const response = await handleParentalConsent(fromSite(`?consent=${token}`, { decision: "lookup" }), deps);
  assertEquals(await response.json(), {
    result: "pending",
    firstName: "Nora",
    expiresAt: "2026-11-15T00:00:00Z",
    reason: "renewal",
    summary: "What changed.",
    agreedBefore: "2026-10-01T12:00:00Z",
  });
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
    renewal: false,
  });
  assertEquals(subject, "You agreed Nora can use Foon");
  assertStringIncludes(text, "You can invite Nora now: in Foon, open Family, then Nora, then Invite.");
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
  const confirmation = confirmationEmail({
    firstName: name,
    withdrawUrl: "w",
    agreedAt: "2026-11-08T15:04:00Z",
    renewal: false,
  });
  const renewed = confirmationEmail({ firstName: name, withdrawUrl: "w", agreedAt: "2026-11-08T15:04:00Z", renewal: true });
  for (const html of [notice.html, confirmation.html, renewed.html]) {
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

Deno.test("a Resend call that doesn't answer in time is a failed send, and names no address", async () => {
  const config = { apiKey: "k", from: "Foon <info@getfoon.com>" };
  let aborted = false;
  const hanging = ((_url: string, init: RequestInit) =>
    new Promise((_resolve, reject) => {
      init.signal?.addEventListener("abort", () => {
        aborted = true;
        reject(new DOMException("The signal has been aborted", "AbortError"));
      });
    })) as unknown as typeof fetch;
  let message = "";
  await sendEmail(config, { to: "a@example.com", subject: "s", text: "t", html: "h" }, hanging, 5).catch((error) =>
    message = error.message
  );
  assert(aborted);
  assertEquals(message, "Resend didn't answer in 5 ms");
  assertEquals(SEND_TIMEOUT_MS, 10_000);
});
