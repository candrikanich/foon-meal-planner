import { assert, assertEquals, assertStringIncludes, assertThrows } from "@std/assert";
import type { Email } from "../_shared/resend.ts";
import { sha256 } from "../_shared/token.ts";
import {
  addressHint,
  type AddSenderDeps,
  handleAddSender,
  type SenderAnswer,
  senderAnswerFromRow,
  SENDER_SUBJECT,
  SenderRefusedError,
} from "./sender.ts";

const HOUSEHOLD = "00000000-0000-0000-0000-0000000000a1";
const ADDRESS = "  Chris.Private@Example.com ";
const SENDER_ID = "c0000000-0000-0000-0000-00000000000c";

function fakeDeps(answer: SenderAnswer | Error = { outcome: "send", id: SENDER_ID }, overrides: Partial<AddSenderDeps> = {}) {
  const sent: Email[] = [];
  const added: { jwt: string; householdId: string; addressHash: string; hint: string; tokenHash: string }[] = [];
  const logs: string[] = [];
  const deps: AddSenderDeps = {
    userFromToken: (jwt) => Promise.resolve(jwt === "good-jwt" ? "a0000000-0000-0000-0000-00000000000a" : null),
    send: (email) => {
      sent.push(email);
      return Promise.resolve();
    },
    addSender: (jwt, householdId, addressHash, hint, tokenHash) => {
      added.push({ jwt, householdId, addressHash, hint, tokenHash });
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
    },
    functionUrl: "https://x.supabase.co/functions/v1/receipt-inbox",
    log: (message, detail) => logs.push(`${message} ${detail ?? ""}`),
    ...overrides,
  };
  return { deps, sent, added, logs };
}

const ask = (body: unknown, { jwt = "good-jwt" as string | null, method = "POST" } = {}) =>
  new Request("https://x.supabase.co/functions/v1/receipt-inbox?sender=add", {
    method,
    headers: jwt === null ? {} : { Authorization: `Bearer ${jwt}` },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

const good = { household_id: HOUSEHOLD, address: ADDRESS };

Deno.test("an adult's new address gets a confirmation link; the database sees only hashes and a hint", async () => {
  const { deps, sent, added, logs } = fakeDeps();
  const response = await handleAddSender(ask(good), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { outcome: "send" });

  assertEquals(added.length, 1);
  const [call] = added;
  assertEquals(call.jwt, "good-jwt", "as the adult, so the database checks their rights");
  assertEquals(call.householdId, HOUSEHOLD);
  assertEquals(call.addressHash, await sha256("chris.private@example.com"));
  assertEquals(call.hint, "c•••@example.com");

  assertEquals(sent.length, 1);
  const [email] = sent;
  assertEquals(email.to, "chris.private@example.com");
  assertEquals(email.subject, SENDER_SUBJECT);
  const link = email.text.match(/https:\/\/\S+\?confirm=(\S+)/);
  assert(link, "the email carries the link");
  assertEquals(await sha256(decodeURIComponent(link[1])), call.tokenHash, "the link's token is the one hashed");
  assertStringIncludes(email.html, "?confirm=");
  assertStringIncludes(email.text, "works for a day");
  assertStringIncludes(email.text, "ignore this email and nothing changes");
  assertEquals(email.idempotencyKey, `receipt-sender-${SENDER_ID}-${call.tokenHash.slice(0, 16)}`);

  const logged = logs.join("\n").toLowerCase();
  assert(!logged.includes("chris.private") && !logged.includes(link[1].toLowerCase()));
});

Deno.test("the database's other answers are passed on without an email", async () => {
  for (const outcome of ["confirmed", "taken", "too_many", "rate_limited"] as const) {
    const { deps, sent } = fakeDeps({ outcome });
    const response = await handleAddSender(ask(good), deps);
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { outcome });
    assertEquals(sent, []);
  }
});

Deno.test("only a signed-in POST with a real address gets anywhere", async () => {
  const { deps, added } = fakeDeps();
  assertEquals((await handleAddSender(ask(good, { method: "GET" }), deps)).status, 405);
  assertEquals((await handleAddSender(ask(good, { jwt: null }), deps)).status, 401);
  assertEquals((await handleAddSender(ask(good, { jwt: "bad-jwt" }), deps)).status, 401);
  for (const address of ["nobody", "a@b", "two@@example.com", `${"a".repeat(250)}@example.com`, ""]) {
    const response = await handleAddSender(ask({ ...good, address }), deps);
    assertEquals(response.status, 400, address);
    assertEquals(await response.json(), { error: "bad_address" });
  }
  const noHousehold = await handleAddSender(ask({ address: ADDRESS }), deps);
  assertEquals(await noHousehold.json(), { error: "bad_request" });
  assertEquals(added, []);
});

Deno.test("with email off, nothing reaches the database", async () => {
  const { deps, added } = fakeDeps(undefined, { send: null });
  const response = await handleAddSender(ask(good), deps);
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { outcome: "email_off" });
  assertEquals(added, []);
});

Deno.test("the database's refusals map to statuses", async () => {
  for (const [code, status] of [["28000", 401], ["42501", 403], ["22023", 400]] as const) {
    const { deps, sent } = fakeDeps(new SenderRefusedError(code));
    assertEquals((await handleAddSender(ask(good), deps)).status, status);
    assertEquals(sent, []);
  }
  const { deps } = fakeDeps(new Error("connection reset"));
  assertEquals((await handleAddSender(ask(good), deps)).status, 500);
});

Deno.test("a failed send is a 502 and logs only the row id", async () => {
  const { deps, logs } = fakeDeps(undefined, { send: () => Promise.reject(new Error("Resend answered 500")) });
  assertEquals((await handleAddSender(ask(good), deps)).status, 502);
  assert(logs.some((line) => line.includes(SENDER_ID)));
  assert(!logs.join("\n").toLowerCase().includes("chris.private"));
});

Deno.test("hints and rows", () => {
  assertEquals(addressHint("chris@gmail.com"), "c•••@gmail.com");
  assertEquals(addressHint(`a@${"d".repeat(100)}.com`).length, 80);
  assertEquals(senderAnswerFromRow({ outcome: "send", id: SENDER_ID }), { outcome: "send", id: SENDER_ID });
  assertEquals(senderAnswerFromRow({ outcome: "taken" }), { outcome: "taken" });
  assertThrows(() => senderAnswerFromRow({ outcome: "send" }));
  assertThrows(() => senderAnswerFromRow({ outcome: "sure" }));
  assertThrows(() => senderAnswerFromRow(null));
});
