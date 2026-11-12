import { assert, assertEquals } from "@std/assert";
import { svixSignature, verifySvix } from "./svix.ts";

const SECRET = `whsec_${btoa("a test signing secret, 32 bytes!")}`;
const NOW = 1_794_000_000_000;
const TIMESTAMP = String(NOW / 1000);
const BODY = '{"type":"email.received","data":{"email_id":"e1"}}';

// Computed independently of svix.ts, as Svix documents it.
async function referenceSignature(secret: string, id: string, timestamp: string, body: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(atob(secret.slice("whsec_".length)), (c) => c.charCodeAt(0)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`));
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}

Deno.test("signs the way Svix documents", async () => {
  assertEquals(await svixSignature(SECRET, "msg_1", TIMESTAMP, BODY), await referenceSignature(SECRET, "msg_1", TIMESTAMP, BODY));
});

Deno.test("a delivery Resend signed passes, among other entries", async () => {
  const signature = await referenceSignature(SECRET, "msg_1", TIMESTAMP, BODY);
  assert(await verifySvix(SECRET, { id: "msg_1", timestamp: TIMESTAMP, signature: `v1,${signature}` }, BODY, NOW));
  const rotated = `v1,${btoa("an old signature")} v1,${signature}`;
  assert(await verifySvix(SECRET, { id: "msg_1", timestamp: TIMESTAMP, signature: rotated }, BODY, NOW));
});

Deno.test("anything else fails", async () => {
  const signature = await referenceSignature(SECRET, "msg_1", TIMESTAMP, BODY);
  const headers = { id: "msg_1", timestamp: TIMESTAMP, signature: `v1,${signature}` };
  assertEquals(await verifySvix(SECRET, headers, `${BODY} `, NOW), false, "a changed body");
  assertEquals(await verifySvix(SECRET, { ...headers, id: "msg_2" }, BODY, NOW), false, "another message id");
  assertEquals(await verifySvix(`whsec_${btoa("another secret")}`, headers, BODY, NOW), false, "another secret");
  assertEquals(await verifySvix(SECRET, { ...headers, signature: `v2,${signature}` }, BODY, NOW), false, "not v1");
  assertEquals(await verifySvix(SECRET, { ...headers, signature: null }, BODY, NOW), false, "no signature");
  assertEquals(await verifySvix(SECRET, { ...headers, timestamp: null }, BODY, NOW), false, "no timestamp");
  assertEquals(await verifySvix(SECRET, { ...headers, id: null }, BODY, NOW), false, "no id");
  assertEquals(await verifySvix("whsec_not base64!", headers, BODY, NOW), false, "a broken secret");
});

Deno.test("a delivery more than five minutes off is a replay", async () => {
  for (const offset of [-301, 301]) {
    const timestamp = String(NOW / 1000 + offset);
    const signature = await referenceSignature(SECRET, "msg_1", timestamp, BODY);
    assertEquals(await verifySvix(SECRET, { id: "msg_1", timestamp, signature: `v1,${signature}` }, BODY, NOW), false);
  }
  const timestamp = String(NOW / 1000 - 299);
  const signature = await referenceSignature(SECRET, "msg_1", timestamp, BODY);
  assert(await verifySvix(SECRET, { id: "msg_1", timestamp, signature: `v1,${signature}` }, BODY, NOW));
});
