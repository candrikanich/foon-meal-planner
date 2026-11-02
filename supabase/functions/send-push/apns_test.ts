import { assert, assertEquals } from "@std/assert";
import {
  alertFor,
  type ApnsConfig,
  apnsConfigFromEnv,
  apnsHost,
  cachedProviderToken,
  deliver,
  knownKinds,
  payloadFor,
  providerToken,
  weekdayOf,
} from "./apns.ts";

async function testConfig(): Promise<{ config: ApnsConfig; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
  return {
    config: {
      teamId: "G374A783RH",
      keyId: "73FNGXV868",
      privateKey: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    },
    publicKey: pair.publicKey,
  };
}

const fromBase64url = (part: string) =>
  Uint8Array.from(atob(part.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
const decode = (part: string) => JSON.parse(new TextDecoder().decode(fromBase64url(part)));

Deno.test("the provider token is an ES256 JWT with only kid, iss and iat", async () => {
  const { config, publicKey } = await testConfig();
  const jwt = await providerToken(config, new Date("2026-11-02T12:00:00Z"));
  const [header, payload, signature] = jwt.split(".");
  assertEquals(decode(header), { alg: "ES256", kid: "73FNGXV868" });
  assertEquals(decode(payload), { iss: "G374A783RH", iat: 1793620800 });
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      fromBase64url(signature),
      new TextEncoder().encode(`${header}.${payload}`),
    ),
  );
});

Deno.test("a cached token is reused for 50 minutes, then replaced", async () => {
  const { config } = await testConfig();
  const saved: { token: string; issuedAt: Date }[] = [];
  const issuedAt = new Date("2026-11-02T12:00:00Z");
  const store = {
    load: () => Promise.resolve({ token: "cached", issuedAt }),
    save: (_: string, token: string, at: Date) => {
      saved.push({ token, issuedAt: at });
      return Promise.resolve();
    },
  };
  assertEquals(await cachedProviderToken(config, store, new Date("2026-11-02T12:49:00Z")), "cached");
  assertEquals(saved.length, 0);
  const fresh = await cachedProviderToken(config, store, new Date("2026-11-02T12:51:00Z"));
  assert(fresh !== "cached");
  assertEquals(saved.map((s) => s.token), [fresh]);
});

Deno.test("with nothing cached a token is signed and saved", async () => {
  const { config } = await testConfig();
  const keys: string[] = [];
  const store = {
    load: () => Promise.resolve(null),
    save: (keyId: string) => {
      keys.push(keyId);
      return Promise.resolve();
    },
  };
  await cachedProviderToken(config, store);
  assertEquals(keys, ["73FNGXV868"]);
});

Deno.test("missing Apple secrets mean no config", () => {
  assertEquals(apnsConfigFromEnv(() => undefined), null);
  assertEquals(apnsConfigFromEnv((key) => (key === "APPLE_PRIVATE_KEY" ? undefined : "x")), null);
});

Deno.test("each device goes to its own environment's host", () => {
  assertEquals(apnsHost("production"), "https://api.push.apple.com");
  assertEquals(apnsHost("sandbox"), "https://api.sandbox.push.apple.com");
});

Deno.test("Plan's set has fixed words and opens the week", () => {
  const alert = alertFor("plan_set")!;
  assertEquals(alert, { title: "This week's dinners are set.", body: "Tap to see the week." });
  assertEquals(payloadFor(alert, { route: "week", date: "2026-11-01" }), {
    aps: { alert, sound: "default" },
    route: "week",
    date: "2026-11-01",
  });
  assertEquals(payloadFor(alert, null), { aps: { alert, sound: "default" } });
  assertEquals(alertFor("something_new"), null);
});

Deno.test("won't be home names the person, first name only, and opens the night", () => {
  const alert = alertFor("not_home", { name: "Ben" }, "2026-11-05")!;
  assertEquals(alert, { title: "Ben won't be home tonight.", body: "Tap to see tonight." });
  assertEquals(payloadFor(alert, { route: "night", night: "n-1", date: "2026-11-05" }), {
    aps: { alert, sound: "default" },
    route: "night",
    night: "n-1",
    date: "2026-11-05",
  });
  assertEquals(alertFor("not_home", {}), null);
  assertEquals(alertFor("not_home", { name: "  " }), null);
  assertEquals(alertFor("not_home", { name: 7 }), null);
});

Deno.test("a claim says the night's weekday from its date, never tonight or tomorrow", () => {
  assertEquals(alertFor("claim", { name: "Ben" }, "2026-11-05"), {
    title: "Ben will cook Thursday.",
    body: "Tap to see the night.",
  });
  assertEquals(alertFor("claim", { name: "Ben" }, "2026-11-08")?.title, "Ben will cook Sunday.");
  assertEquals(alertFor("claim", { name: "Ben" }, null), null);
  assertEquals(alertFor("claim", { name: "Ben" }, "Thursday"), null);
  assertEquals(alertFor("claim", {}, "2026-11-05"), null);
});

Deno.test("the known kinds are exactly the ones with words", () => {
  assertEquals([...knownKinds].sort(), [
    "claim",
    "new_requests",
    "not_home",
    "plan_set",
    "request_planned",
    "tonight_poll",
    "urgent_item",
  ]);
  for (const kind of knownKinds) assert(alertFor(kind, { name: "Ben", count: 1 }, "2026-11-05"));
  for (const kind of ["something_new", "weekly_recap", "constructor", "toString", ""]) {
    assert(!knownKinds.has(kind));
    assertEquals(alertFor(kind, { name: "Ben" }, "2026-11-05"), null);
  }
});

Deno.test("an urgent item names who added it, never the item, and opens the list", () => {
  const alert = alertFor("urgent_item", { name: "Ben", item: "Milk" })!;
  assertEquals(alert, { title: "Ben added something for tonight.", body: "Tap to see the list." });
  assertEquals(payloadFor(alert, { route: "list" }), { aps: { alert, sound: "default" }, route: "list" });
  assertEquals(alertFor("urgent_item", {}), null);
});

Deno.test("a tonight poll names who started it", () => {
  assertEquals(alertFor("tonight_poll", { name: "Ben" }, "2026-11-05"), {
    title: "Ben started a vote on dinner.",
    body: "Tap to vote.",
  });
  assertEquals(alertFor("tonight_poll", {}), null);
});

Deno.test("your idea made the plan says the weekday, never the dish", () => {
  assertEquals(alertFor("request_planned", {}, "2026-11-06"), {
    title: "Your idea made Friday.",
    body: "Tap to see the night.",
  });
  assertEquals(alertFor("request_planned", { name: "Ben", dish: "Crab legs" }, "2026-11-06")?.title, "Your idea made Friday.");
  assertEquals(alertFor("request_planned", {}, null), null);
});

Deno.test("the ideas digest counts, names one person, and never a dish", () => {
  assertEquals(alertFor("new_requests", { count: 2 }), { title: "2 new dinner ideas.", body: "Tap to see them." });
  assertEquals(alertFor("new_requests", { count: 1 }), { title: "1 new dinner idea.", body: "Tap to see it." });
  assertEquals(alertFor("new_requests", { count: 2, name: "Ben" }), {
    title: "Ben has 2 new dinner ideas.",
    body: "Tap to see them.",
  });
  assertEquals(alertFor("new_requests", { count: 1, name: "Ben", dish: "Crab legs" })?.title, "Ben has a new dinner idea.");
  assertEquals(alertFor("new_requests", {}), null);
  assertEquals(alertFor("new_requests", { count: 0 }), null);
  assertEquals(alertFor("new_requests", { count: "2" }), null);
  assertEquals(alertFor("new_requests", { count: 1.5 }), null);
});

Deno.test("only the name is read from args", () => {
  assertEquals(alertFor("not_home", { name: "Ben", dish: "Chili" })?.title, "Ben won't be home tonight.");
});

Deno.test("weekdays come from the calendar date, whatever the server's zone", () => {
  assertEquals(weekdayOf("2026-11-02"), "Monday");
  assertEquals(weekdayOf("2026-12-31"), "Thursday");
  assertEquals(weekdayOf("2026-1-1"), null);
});

const device = { token: "ab".repeat(32), environment: "sandbox" as const };
const payload = payloadFor(alertFor("plan_set")!, { route: "week", date: "2026-11-01" });

Deno.test("a push is posted with the topic, type and provider token", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init! });
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as typeof fetch;
  assertEquals(await deliver(device, payload, "jwt-1", fakeFetch), "delivered");
  assertEquals(calls[0].url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
  const headers = calls[0].init.headers as Record<string, string>;
  assertEquals(headers.authorization, "bearer jwt-1");
  assertEquals(headers["apns-topic"], "com.andrikanich.foon");
  assertEquals(headers["apns-push-type"], "alert");
  assertEquals(JSON.parse(String(calls[0].init.body)), payload);
});

Deno.test("410 and dead-token reasons say the token is gone; anything else is retried", async () => {
  const replying = (status: number, reason?: string) =>
    (() => Promise.resolve(Response.json(reason ? { reason } : {}, { status }))) as typeof fetch;
  assertEquals(await deliver(device, payload, "j", replying(410, "Unregistered")), "dead_token");
  assertEquals(await deliver(device, payload, "j", replying(400, "BadDeviceToken")), "dead_token");
  assertEquals(await deliver(device, payload, "j", replying(400, "DeviceTokenNotForTopic")), "dead_token");
  assertEquals(await deliver(device, payload, "j", replying(429, "TooManyRequests")), "retry");
  assertEquals(await deliver(device, payload, "j", replying(403, "ExpiredProviderToken")), "retry");
  assertEquals(await deliver(device, payload, "j", replying(500)), "retry");
  const offline = (() => Promise.reject(new TypeError("network"))) as typeof fetch;
  assertEquals(await deliver(device, payload, "j", offline), "retry");
});
