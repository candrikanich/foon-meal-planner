import { assert, assertEquals, assertRejects } from "@std/assert";
import { sha256 } from "../_shared/token.ts";
import {
  addressOf,
  fetchReceivedEmail,
  handleInbound,
  type InboundDeps,
  inboxToken,
  type ReceivedEmail,
  TransientError,
} from "./inbound.ts";
import { svixSignature } from "./svix.ts";

const SECRET = `whsec_${btoa("a test signing secret, 32 bytes!")}`;
const NOW = 1_794_000_000_000;
const TOKEN = "0123456789abcdef";
const SENDER = "Chris.Private@Example.com";

const received: ReceivedEmail = {
  from: `Chris <${SENDER}>`,
  text: "GREEN GROCER\nBANANAS 1.29\nMILK 3.99\nTOTAL 5.28",
  html: "<p>ignored</p>",
  authentication: { spf: "pass", dkim: "pass", dmarc: "pass" },
};

function fakeDeps(email: ReceivedEmail | null | Error = received, overrides: Partial<InboundDeps> = {}) {
  const recorded: { token: string; senderHash: string; sourceId: string; lines: string[] }[] = [];
  const fetched: string[] = [];
  const logs: string[] = [];
  const deps: InboundDeps = {
    webhookSecret: SECRET,
    inboxDomain: "in.getfoon.com",
    getEmail: (id) => {
      fetched.push(id);
      return email instanceof Error ? Promise.reject(email) : Promise.resolve(email);
    },
    record: (token, senderHash, sourceId, lines) => {
      recorded.push({ token, senderHash, sourceId, lines });
      return Promise.resolve("stored");
    },
    now: () => NOW,
    log: (message, detail) => logs.push(`${message} ${detail ?? ""}`),
    ...overrides,
  };
  return { deps, recorded, fetched, logs };
}

const event = (data: Record<string, unknown> = {}, type = "email.received") =>
  JSON.stringify({ type, created_at: "2026-11-12T00:00:00Z", data: { email_id: "em_1", to: [`r-${TOKEN}@in.getfoon.com`], ...data } });

async function delivery(body: string, { signed = true, timestamp = String(NOW / 1000) } = {}) {
  const signature = signed ? await svixSignature(SECRET, "msg_1", timestamp, body) : btoa("forged");
  return new Request("https://x.supabase.co/functions/v1/receipt-inbox", {
    method: "POST",
    headers: { "svix-id": "msg_1", "svix-timestamp": timestamp, "svix-signature": `v1,${signature}` },
    body,
  });
}

Deno.test("a signed receipt from a confirmed address is recorded with its sender's hash, never the address", async () => {
  const { deps, recorded, fetched, logs } = fakeDeps();
  const response = await handleInbound(await delivery(event()), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "stored" });
  assertEquals(fetched, ["em_1"]);
  assertEquals(recorded, [{
    token: TOKEN,
    senderHash: await sha256(SENDER.toLowerCase()),
    sourceId: "em_1",
    lines: ["GREEN GROCER", "BANANAS 1.29", "MILK 3.99", "TOTAL 5.28"],
  }]);
  const logged = logs.join("\n").toLowerCase();
  for (const secret of [SENDER.toLowerCase(), TOKEN, "bananas"]) assert(!logged.includes(secret), secret);
});

Deno.test("an unsigned, forged or stale delivery is refused before anything is fetched", async () => {
  const { deps, fetched } = fakeDeps();
  assertEquals((await handleInbound(await delivery(event(), { signed: false }), deps)).status, 401);
  assertEquals((await handleInbound(await delivery(event(), { timestamp: String(NOW / 1000 - 600) }), deps)).status, 401);
  const bare = new Request("https://x/functions/v1/receipt-inbox", { method: "POST", body: event() });
  assertEquals((await handleInbound(bare, deps)).status, 401);
  assertEquals(fetched, []);
});

Deno.test("while it isn't set up, Resend is asked to hold the mail and retry", async () => {
  for (const missing of [{ webhookSecret: undefined }, { getEmail: null }]) {
    const { deps } = fakeDeps(received, missing);
    assertEquals((await handleInbound(await delivery(event()), deps)).status, 503);
  }
});

Deno.test("other events, and mail to no inbox address, are ignored", async () => {
  const { deps, fetched, recorded } = fakeDeps();
  assertEquals(await (await handleInbound(await delivery(event({}, "email.sent")), deps)).json(), { result: "ignored" });
  const elsewhere = event({ to: ["someone@in.getfoon.com", `r-${TOKEN}@other.example`] });
  assertEquals(await (await handleInbound(await delivery(elsewhere), deps)).json(), { result: "dropped" });
  assertEquals(fetched, []);
  assertEquals(recorded, []);
});

Deno.test("the inbox can be in received_for, named, or in capitals", async () => {
  const { deps, recorded } = fakeDeps();
  const body = event({ to: ["family@example.com"], received_for: `Foon <R-${TOKEN.toUpperCase()}@IN.GETFOON.COM>` });
  assertEquals((await handleInbound(await delivery(body), deps)).status, 200);
  assertEquals(recorded[0]?.token, TOKEN);
});

Deno.test("mail that fails DMARC, is too big, or has no lines is dropped without recording", async () => {
  const cases: ReceivedEmail[] = [
    { ...received, authentication: { spf: "pass", dkim: "pass", dmarc: "fail" } },
    { ...received, authentication: { spf: "gray", dkim: "gray", dmarc: "gray" } },
    { ...received, authentication: { spf: "fail", dkim: "fail", dmarc: "gray" } },
    { ...received, authentication: { spf: "pass", dkim: "pass", dmarc: "processing_failed" } },
    { ...received, authentication: { spf: "pass", dkim: "pass", dmarc: "unknown" } },
    { ...received, authentication: null },
    { ...received, from: "not an address" },
    { ...received, text: "x".repeat(1_500_000), html: "y".repeat(600_000) },
    { ...received, text: "\n \n", html: "<div> </div>" },
  ];
  for (const email of cases) {
    const { deps, recorded } = fakeDeps(email);
    const response = await handleInbound(await delivery(event()), deps);
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { result: "dropped" });
    assertEquals(recorded, []);
  }
});

Deno.test("a gray DMARC result is kept when SPF or DKIM passed, as from Gmail or a DreamHost domain", async () => {
  for (const [spf, dkim] of [["pass", "pass"], ["gray", "pass"], ["pass", "fail"], ["pass", "gray"]]) {
    const { deps, recorded } = fakeDeps({ ...received, authentication: { spf, dkim, dmarc: "gray" } });
    const response = await handleInbound(await delivery(event()), deps);
    assertEquals(await response.json(), { result: "stored" }, `${spf} ${dkim}`);
    assertEquals(recorded.length, 1);
  }
});

Deno.test("a dropped email logs its authentication results, so a drop can be explained", async () => {
  const { deps, logs } = fakeDeps({ ...received, authentication: { spf: "pass", dkim: "fail", dmarc: "fail" } });
  await handleInbound(await delivery(event()), deps);
  assert(logs.some((line) => line.includes("em_1") && line.includes("spf=pass dkim=fail dmarc=fail")), logs.join("\n"));
});

Deno.test("a result word Resend doesn't define is logged as other", async () => {
  const odd = { spf: "pass", dkim: "a@b.com", dmarc: "softfail" };
  const { deps, logs } = fakeDeps({ ...received, authentication: odd });
  await handleInbound(await delivery(event()), deps);
  assert(logs.some((line) => line.includes("spf=pass dkim=other dmarc=other")), logs.join("\n"));
  assert(!logs.join("\n").includes("a@b.com"));
});

Deno.test("a missing email is dropped; a transient failure asks Resend to retry", async () => {
  const missing = fakeDeps(null);
  assertEquals(await (await handleInbound(await delivery(event()), missing.deps)).json(), { result: "dropped" });
  const down = fakeDeps(new TransientError("Resend answered 503"));
  assertEquals((await handleInbound(await delivery(event()), down.deps)).status, 500);
  const dbDown = fakeDeps(received, { record: () => Promise.reject(new Error("connection reset")) });
  assertEquals((await handleInbound(await delivery(event()), dbDown.deps)).status, 500);
});

Deno.test("every database outcome is a 200, so Resend doesn't retry", async () => {
  for (const outcome of ["stored", "duplicate", "unknown_inbox", "unknown_sender", "over_limit", "bad_lines"]) {
    const { deps, logs } = fakeDeps(received, { record: () => Promise.resolve(outcome) });
    const response = await handleInbound(await delivery(event()), deps);
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { result: outcome });
    assert(logs.some((line) => line.includes("em_1") && line.includes(outcome)));
  }
});

Deno.test("reads addresses and inbox tokens", () => {
  assertEquals(addressOf(' "Doe, J" <J.Doe@Example.com> '), "j.doe@example.com");
  assertEquals(addressOf("a@b.co"), "a@b.co");
  assertEquals(addressOf('"a@b.co" <a@b.co>'), "a@b.co");
  assertEquals(addressOf("a@evil.com,<victim@gmail.com>"), null);
  assertEquals(addressOf("nobody"), null);
  assertEquals(addressOf(null), null);
  assertEquals(inboxToken([`r-${TOKEN}@in.getfoon.com`], "in.getfoon.com"), TOKEN);
  assertEquals(inboxToken([`r-${TOKEN}@inXgetfoon.com`], "in.getfoon.com"), null, "the dot is literal");
  assertEquals(inboxToken([`r-${TOKEN}0@in.getfoon.com`, 7, null], "in.getfoon.com"), null);
});

Deno.test("fetching: 404 is null, 5xx and 429 and a hang are transient, the body is the email", async () => {
  const answer = (status: number, body: unknown = {}) =>
    (() => Promise.resolve(new Response(JSON.stringify(body), { status }))) as unknown as typeof fetch;
  let seen: { url: string; auth: string | null } | undefined;
  const spy = ((url: string, init: RequestInit) => {
    seen = { url, auth: new Headers(init.headers).get("Authorization") };
    return Promise.resolve(new Response(JSON.stringify(received)));
  }) as unknown as typeof fetch;
  assertEquals(await fetchReceivedEmail("re_key", "em_1", spy), received);
  assertEquals(seen, { url: "https://api.resend.com/emails/receiving/em_1", auth: "Bearer re_key" });
  assertEquals(await fetchReceivedEmail("re_key", "em_1", answer(404)), null);
  await assertRejects(() => fetchReceivedEmail("re_key", "em_1", answer(503)), TransientError);
  await assertRejects(() => fetchReceivedEmail("re_key", "em_1", answer(429)), TransientError);
  await assertRejects(() => fetchReceivedEmail("re_key", "em_1", answer(401)), Error);
  const hang = ((_url: string, init: RequestInit) =>
    new Promise((_, reject) => init.signal?.addEventListener("abort", () => reject(init.signal?.reason)))) as typeof fetch;
  await assertRejects(() => fetchReceivedEmail("re_key", "em_1", hang, 10), TransientError);
});
