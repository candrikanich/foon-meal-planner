import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import type { Email } from "../_shared/resend.ts";
import { type AccountEmailDeps, BATCH_SIZE, type ClaimedEmail, handleAccountEmail, RUN_BUDGET_MS } from "./handler.ts";

const welcome = (id: string): ClaimedEmail => ({ id, kind: "welcome", email: `${id}@example.com`, payload: {}, attempts: 1 });

function fakeDeps(rows: ClaimedEmail[][], overrides: Partial<AccountEmailDeps> = {}) {
  const sent: Email[] = [];
  const steps: string[] = [];
  const logs: string[] = [];
  const batches = [...rows];
  const deps: AccountEmailDeps = {
    cronSecret: "secret",
    siteUrl: "https://getfoon.com",
    send: (email) => {
      sent.push(email);
      return Promise.resolve();
    },
    claim: (limit) => {
      steps.push(`claim ${limit}`);
      return Promise.resolve(batches.shift() ?? []);
    },
    markSent: (id) => {
      steps.push(`sent ${id}`);
      return Promise.resolve();
    },
    release: (id, code, giveUp) => {
      steps.push(`release ${id} ${code} ${giveUp}`);
      return Promise.resolve();
    },
    now: () => 0,
    log: (message, detail) => logs.push(`${message} ${detail ?? ""}`),
    ...overrides,
  };
  return { deps, sent, steps, logs };
}

const post = (secret: string | null = "secret", method = "POST") =>
  new Request("http://localhost/account-email", {
    method,
    headers: secret === null ? {} : { "x-account-email-secret": secret },
  });

Deno.test("only a POST with the cron secret runs", async () => {
  const { deps, steps } = fakeDeps([[welcome("a")]]);
  assertEquals((await handleAccountEmail(post("secret", "GET"), deps)).status, 405);
  assertEquals((await handleAccountEmail(post(null), deps)).status, 401);
  assertEquals((await handleAccountEmail(post("wrong"), deps)).status, 401);
  assertEquals(steps, []);
});

Deno.test("with no secret configured, nothing runs", async () => {
  const { deps, steps } = fakeDeps([[welcome("a")]], { cronSecret: undefined });
  assertEquals((await handleAccountEmail(post("secret"), deps)).status, 401);
  assertEquals(steps, []);
});

Deno.test("with email off, nothing is claimed, so no row is used up", async () => {
  const { deps, steps } = fakeDeps([[welcome("a")]], { send: null });
  const response = await handleAccountEmail(post(), deps);
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "email_off" });
  assertEquals(steps, []);
});

Deno.test("claims, sends each to its address, and marks it sent", async () => {
  const { deps, sent, steps } = fakeDeps([[welcome("a"), welcome("b")]]);
  const response = await handleAccountEmail(post(), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { sent: 2, failed: 0, unwritable: 0 });
  assertEquals(sent.map((email) => email.to), ["a@example.com", "b@example.com"]);
  assertEquals(sent[0].subject, "Welcome to Foon");
  assertEquals(steps, [`claim ${BATCH_SIZE}`, "sent a", "sent b"]);
});

Deno.test("a failed send is released with a code to try again, and never logs the address", async () => {
  const { deps, steps, logs } = fakeDeps([[welcome("a"), welcome("b")]], {
    send: (email) => email.to.startsWith("a") ? Promise.reject(new Error("Resend answered 429")) : Promise.resolve(),
  });
  const response = await handleAccountEmail(post(), deps);
  assertEquals(await response.json(), { sent: 1, failed: 1, unwritable: 0 });
  assertEquals(steps.slice(1), ["release a resend_429 false", "sent b"]);
  assert(logs.every((line) => !line.includes("@")));
});

Deno.test("a timeout is its own code", async () => {
  const { deps, steps } = fakeDeps([[welcome("a")]], {
    send: () => Promise.reject(new Error("Resend didn't answer in 10000 ms")),
  });
  await handleAccountEmail(post(), deps);
  assertEquals(steps.at(-1), "release a timeout false");
});

Deno.test("a row it can't write is given up, not retried", async () => {
  const rows: ClaimedEmail[] = [
    { id: "x", kind: "weekly_plan", email: "x@example.com", payload: {}, attempts: 1 },
    { id: "y", kind: "subscription_ending", email: "y@example.com", payload: {}, attempts: 1 },
  ];
  const { deps, sent, steps } = fakeDeps([rows]);
  const response = await handleAccountEmail(post(), deps);
  assertEquals(await response.json(), { sent: 0, failed: 0, unwritable: 2 });
  assertEquals(sent, []);
  assertEquals(steps.slice(1), ["release x no_words true", "release y no_words true"]);
});

Deno.test("subscription notices carry their date", async () => {
  const rows: ClaimedEmail[] = [
    {
      id: "s",
      kind: "subscription_started",
      email: "s@example.com",
      payload: { trial: true, ends_at: "2026-12-11T15:00:00+00:00", product_id: "foon.family.monthly" },
      attempts: 1,
    },
    {
      id: "e",
      kind: "subscription_ended",
      email: "e@example.com",
      payload: { trial: false, ends_at: "2027-01-02T00:00:00Z" },
      attempts: 1,
    },
  ];
  const { deps, sent } = fakeDeps([rows]);
  await handleAccountEmail(post(), deps);
  assertEquals(sent[0].subject, "Your Foon free trial has started");
  assertStringIncludes(sent[0].text, "December 11, 2026");
  assertEquals(sent[1].subject, "Your Foon subscription has ended");
  assertStringIncludes(sent[1].text, "January 2, 2027");
});

Deno.test("keeps claiming full batches, and stops at a short one", async () => {
  const full = Array.from({ length: BATCH_SIZE }, (_, i) => welcome(`r${i}`));
  const { deps, steps } = fakeDeps([full, [welcome("last")]]);
  const response = await handleAccountEmail(post(), deps);
  assertEquals((await response.json()).sent, BATCH_SIZE + 1);
  assertEquals(steps.filter((step) => step.startsWith("claim")).length, 2);
});

Deno.test("stops claiming when the run's time is up", async () => {
  const full = Array.from({ length: BATCH_SIZE }, (_, i) => welcome(`r${i}`));
  let clock = 0;
  const { deps, steps } = fakeDeps([full, full, full], {
    now: () => clock,
    markSent: () => {
      clock += RUN_BUDGET_MS;
      return Promise.resolve();
    },
  });
  await handleAccountEmail(post(), deps);
  assertEquals(steps.filter((step) => step.startsWith("claim")).length, 1);
});

Deno.test("a database error ends the run with a 500; what's claimed goes out again later", async () => {
  const { deps, logs } = fakeDeps([[welcome("a")]], { markSent: () => Promise.reject(new Error("db down")) });
  const response = await handleAccountEmail(post(), deps);
  assertEquals(response.status, 500);
  assertEquals((await response.json()).error, "run_failed");
  assert(logs.some((line) => line.includes("db down")));
});
