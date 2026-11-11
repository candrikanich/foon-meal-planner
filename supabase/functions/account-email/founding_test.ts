import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import type { Email } from "../_shared/resend.ts";
import { type FoundingDeps, handleFoundingUpdate, PREVIEW_USER } from "./founding.ts";

function fakeDeps(overrides: Partial<FoundingDeps> = {}) {
  const sent: Email[] = [];
  const queued: { subject: string; body: string }[] = [];
  const deps: FoundingDeps = {
    secret: "founding-secret",
    previewTo: "chris@example.com",
    postalAddress: ["PO Box 1", "Town, OH 44000"],
    send: (email) => {
      sent.push(email);
      return Promise.resolve();
    },
    unsubscribeUrl: (kind, userId) => Promise.resolve(`https://x/account-email?unsubscribe=${kind}.${userId}.sig`),
    audience: () => Promise.resolve(12),
    queue: (subject, body) => {
      queued.push({ subject, body });
      return Promise.resolve({ updateId: "u1", queued: 12, repeat: false });
    },
    log: () => {},
    ...overrides,
  };
  return { deps, sent, queued };
}

const call = (mode: string, body: unknown, secret: string | null = "founding-secret", method = "POST") =>
  new Request(`https://x/functions/v1/account-email?founding=${mode}`, {
    method,
    headers: secret === null ? {} : { "x-founding-updates-secret": secret },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

const update = { markdown: "# What's new in Foon\n\nHello, founding families.\n\n- Lists\n- Polls" };

Deno.test("only a POST with the founding secret does anything", async () => {
  const { deps, sent, queued } = fakeDeps();
  assertEquals((await handleFoundingUpdate(call("preview", update, null), deps)).status, 401);
  assertEquals((await handleFoundingUpdate(call("preview", update, "wrong"), deps)).status, 401);
  assertEquals((await handleFoundingUpdate(call("preview", update, "founding-secret", "GET"), deps)).status, 405);
  const unset = fakeDeps({ secret: undefined });
  assertEquals((await handleFoundingUpdate(call("preview", update), unset.deps)).status, 401);
  assertEquals([sent, queued], [[], []]);
});

Deno.test("no marketing email goes without the postal address", async () => {
  const { deps, sent, queued } = fakeDeps({ postalAddress: null });
  for (const mode of ["preview", "send"]) {
    const response = await handleFoundingUpdate(call(mode, update), deps);
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: "no_postal_address" });
  }
  assertEquals([sent, queued], [[], []]);
});

Deno.test("a preview goes only to the preview address, marked, and says how many would get it", async () => {
  const { deps, sent, queued } = fakeDeps();
  const response = await handleFoundingUpdate(call("preview", update), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { mode: "preview", subject: "What's new in Foon", audience: 12 });
  assertEquals(sent.length, 1);
  assertEquals(sent[0].to, "chris@example.com");
  assertEquals(sent[0].subject, "[Preview] What's new in Foon");
  assertStringIncludes(sent[0].text, "PO Box 1");
  assertStringIncludes(sent[0].text, `founding_updates.${PREVIEW_USER}.sig`, "a link that unsubscribes nobody");
  assertEquals(queued, []);
});

Deno.test("no preview without a preview address", async () => {
  const { deps, sent } = fakeDeps({ previewTo: undefined });
  const response = await handleFoundingUpdate(call("preview", update), deps);
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "no_preview_address" });
  assertEquals(sent, []);
});

Deno.test("send queues it for everyone opted in; the outbox paces it", async () => {
  const { deps, sent, queued } = fakeDeps();
  const response = await handleFoundingUpdate(call("send", { subject: "Big news", body: "We launched." }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { mode: "send", subject: "Big news", updateId: "u1", queued: 12, repeat: false });
  assertEquals(queued, [{ subject: "Big news", body: "We launched." }]);
  assertEquals(sent, [], "nothing is sent directly: the account-email run sends at 200 an hour");
});

Deno.test("send while account email is off says so", async () => {
  const { deps } = fakeDeps({ queue: () => Promise.resolve("email_off" as const) });
  const response = await handleFoundingUpdate(call("send", update), deps);
  assertEquals(response.status, 409);
  assertEquals(await response.json(), { error: "email_off" });
});

Deno.test("an update without a subject or body, or an unknown mode, is refused", async () => {
  const { deps, sent, queued } = fakeDeps();
  assertEquals((await handleFoundingUpdate(call("send", { markdown: "no heading" }), deps)).status, 400);
  assertEquals((await handleFoundingUpdate(call("send", { subject: "Hi" }), deps)).status, 400);
  assertEquals((await handleFoundingUpdate(call("blast", update), deps)).status, 400);
  const notJson = new Request("https://x/functions/v1/account-email?founding=send", {
    method: "POST",
    headers: { "x-founding-updates-secret": "founding-secret" },
    body: "{",
  });
  assertEquals((await handleFoundingUpdate(notJson, deps)).status, 400);
  assertEquals([sent, queued], [[], []]);
});

Deno.test("with Resend off, nothing goes", async () => {
  const { deps } = fakeDeps({ send: null });
  const response = await handleFoundingUpdate(call("preview", update), deps);
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "email_off" });
});

Deno.test("a failure is a 500 that names no address", async () => {
  const logs: string[] = [];
  const { deps } = fakeDeps({
    send: () => Promise.reject(new Error("Resend answered 422")),
    log: (message, detail) => logs.push(`${message} ${detail ?? ""}`),
  });
  const response = await handleFoundingUpdate(call("preview", update), deps);
  assertEquals(response.status, 500);
  assert(logs.every((line) => !line.includes("@")));
});
