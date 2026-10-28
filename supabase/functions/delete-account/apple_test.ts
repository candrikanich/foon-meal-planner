import { assert, assertEquals, assertRejects } from "@std/assert";
import {
  AppleAccountMismatch,
  type AppleConfig,
  appleConfigFromEnv,
  clientSecret,
  idTokenSubject,
  revokeAppleToken,
} from "./apple.ts";

const fakeIDToken = (sub: string) => `h.${btoa(JSON.stringify({ sub, iss: "https://appleid.apple.com" }))}.s`;

async function testConfig(): Promise<{ config: AppleConfig; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
  return {
    config: {
      teamId: "G374A783RH",
      keyId: "KEY123",
      clientId: "com.andrikanich.foon",
      privateKey: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    },
    publicKey: pair.publicKey,
  };
}

const decode = (part: string) =>
  JSON.parse(new TextDecoder().decode(
    Uint8Array.from(atob(part.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0)),
  ));

Deno.test("the client secret is an ES256 JWT Apple can verify", async () => {
  const { config, publicKey } = await testConfig();
  const jwt = await clientSecret(config, new Date("2026-10-28T12:00:00Z"));
  const [header, payload, signature] = jwt.split(".");
  assertEquals(decode(header), { alg: "ES256", kid: "KEY123" });
  assertEquals(decode(payload), {
    iss: "G374A783RH",
    iat: 1793188800,
    exp: 1793189100,
    aud: "https://appleid.apple.com",
    sub: "com.andrikanich.foon",
  });
  const raw = new Uint8Array(
    Array.from(atob(signature.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0)),
  );
  assertEquals(raw.length, 64, "raw r||s, as JWS wants");
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      raw,
      new TextEncoder().encode(`${header}.${payload}`),
    ),
  );
});

Deno.test("the code is exchanged, then its refresh token revoked", async () => {
  const { config } = await testConfig();
  const calls: { url: string; form: URLSearchParams }[] = [];
  const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), form: new URLSearchParams(String(init?.body)) });
    return String(input).endsWith("/auth/token")
      ? Promise.resolve(Response.json({ access_token: "a", refresh_token: "r", id_token: fakeIDToken("apple-1") }))
      : Promise.resolve(new Response(null, { status: 200 }));
  }) as typeof fetch;

  await revokeAppleToken("code-1", "apple-1", config, fakeFetch);

  assertEquals(calls.map((c) => c.url), [
    "https://appleid.apple.com/auth/token",
    "https://appleid.apple.com/auth/revoke",
  ]);
  assertEquals(calls[0].form.get("code"), "code-1");
  assertEquals(calls[0].form.get("grant_type"), "authorization_code");
  assertEquals(calls[1].form.get("token"), "r");
  assertEquals(calls[1].form.get("token_type_hint"), "refresh_token");
  assertEquals(calls[1].form.get("client_id"), "com.andrikanich.foon");
});

Deno.test("a refused exchange throws, so nothing is deleted", async () => {
  const { config } = await testConfig();
  const fakeFetch = (() => Promise.resolve(new Response("invalid_grant", { status: 400 }))) as typeof fetch;
  await assertRejects(() => revokeAppleToken("expired", "apple-1", config, fakeFetch));
});

Deno.test("missing secrets mean no config", () => {
  assertEquals(appleConfigFromEnv(() => undefined), null);
  assertEquals(appleConfigFromEnv((key) => (key === "APPLE_KEY_ID" ? undefined : "x")), null);
});

Deno.test("another Apple ID's code is not revoked", async () => {
  const { config } = await testConfig();
  const urls: string[] = [];
  const fakeFetch = ((input: string | URL | Request) => {
    urls.push(String(input));
    return Promise.resolve(Response.json({ refresh_token: "r", id_token: fakeIDToken("someone-else") }));
  }) as typeof fetch;
  await assertRejects(() => revokeAppleToken("code-1", "apple-1", config, fakeFetch), AppleAccountMismatch);
  assertEquals(urls, ["https://appleid.apple.com/auth/token"]);
});

Deno.test("without a refresh token the access token is revoked", async () => {
  const { config } = await testConfig();
  const forms: URLSearchParams[] = [];
  const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
    forms.push(new URLSearchParams(String(init?.body)));
    return Promise.resolve(
      String(input).endsWith("/auth/token")
        ? Response.json({ access_token: "a", id_token: fakeIDToken("apple-1") })
        : new Response(null, { status: 200 }),
    );
  }) as typeof fetch;
  await revokeAppleToken("code-1", "apple-1", config, fakeFetch);
  assertEquals(forms[1].get("token"), "a");
  assertEquals(forms[1].get("token_type_hint"), "access_token");
});

Deno.test("the id token's subject is read, junk is not", () => {
  assertEquals(idTokenSubject(fakeIDToken("apple-1")), "apple-1");
  assertEquals(idTokenSubject("not-a-jwt"), null);
  assertEquals(idTokenSubject(undefined), null);
});
