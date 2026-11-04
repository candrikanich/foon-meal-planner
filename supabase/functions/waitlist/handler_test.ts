import { assertEquals, assertStringIncludes } from "@std/assert";
import { sha256, signer } from "./crypto.ts";
import { confirmationEmail, resendConfigFromEnv, sendViaResend } from "./email.ts";
import { type ConfirmOutcome, handleWaitlist, type JoinOutcome, type WaitlistDeps } from "./handler.ts";

const id = "11111111-2222-3333-4444-555555555555";
const sign = signer("service-key");
const token = "t".repeat(43);

function fakeDeps(overrides: Partial<WaitlistDeps> = {}, join: JoinOutcome = "send", confirm: ConfirmOutcome = "confirmed") {
  const joins: Array<{ email: string; firstName: string | null; tokenHash: string; ipHash: string }> = [];
  const sent: Array<{ to: string; confirmUrl: string; unsubscribeUrl: string }> = [];
  const logs: string[] = [];
  const unsubscribed: string[] = [];
  const deps: WaitlistDeps = {
    allowedOrigins: ["https://getfoon.com", "http://localhost:3000"],
    siteUrl: "https://getfoon.com",
    functionUrl: "https://x.supabase.co/functions/v1/waitlist",
    join: (input) => {
      joins.push(input);
      return Promise.resolve(join);
    },
    confirm: () => Promise.resolve(confirm),
    unsubscribe: (target) => {
      unsubscribed.push(target);
      return Promise.resolve(true);
    },
    idFor: () => Promise.resolve(id),
    newToken: () => token,
    sha256,
    sign,
    sendConfirmation: (message) => {
      sent.push(message);
      return Promise.resolve("sent");
    },
    log: (message) => logs.push(message),
    ...overrides,
  };
  return { deps, joins, sent, logs, unsubscribed };
}

const post = (body: unknown, headers: Record<string, string> = {}, path = "") =>
  new Request(`http://localhost/waitlist${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://getfoon.com", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

Deno.test("a signup stores a hashed token and emails the link", async () => {
  const { deps, joins, sent } = fakeDeps();
  const response = await handleWaitlist(post({ email: " Pat@Example.com ", firstName: "Pat" }, { "x-forwarded-for": "1.2.3.4, 5.6.7.8" }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { ok: true });
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://getfoon.com");
  assertEquals(joins[0].email, "Pat@Example.com");
  assertEquals(joins[0].firstName, "Pat");
  assertEquals(joins[0].tokenHash, await sha256(token));
  assertEquals(joins[0].tokenHash === token, false);
  assertEquals(joins[0].ipHash, await sign("ip:1.2.3.4"));
  assertEquals(sent[0].confirmUrl, `https://x.supabase.co/functions/v1/waitlist?confirm=${token}`);
  assertStringIncludes(sent[0].unsubscribeUrl, `?unsubscribe=${id}.${await sign(id)}`);
});

Deno.test("the answer is the same whether or not the email was already here", async () => {
  const fresh = fakeDeps({}, "send");
  const known = fakeDeps({}, "skip");
  const a = await handleWaitlist(post({ email: "a@example.com" }), fresh.deps);
  const b = await handleWaitlist(post({ email: "a@example.com" }), known.deps);
  assertEquals([a.status, await a.text()], [b.status, await b.text()]);
  assertEquals(known.sent.length, 0);
});

Deno.test("a filled honeypot looks like success and stores nothing", async () => {
  const { deps, joins, sent } = fakeDeps();
  const response = await handleWaitlist(post({ email: "bot@example.com", website: "http://spam" }), deps);
  assertEquals(response.status, 200);
  assertEquals(joins.length + sent.length, 0);
});

Deno.test("bad emails and bad bodies are 400", async () => {
  const { deps, joins } = fakeDeps();
  for (const body of [{ email: "nope" }, {}, { email: "a@b.co", firstName: "x".repeat(61) }, "not json"]) {
    assertEquals((await handleWaitlist(post(body), deps)).status, 400);
  }
  assertEquals(joins.length, 0);
});

Deno.test("the rate limit is a 429 and sends nothing", async () => {
  const { deps, sent } = fakeDeps({}, "rate_limited");
  assertEquals((await handleWaitlist(post({ email: "a@example.com" }), deps)).status, 429);
  assertEquals(sent.length, 0);
});

Deno.test("without email configured the signup still succeeds and the log says email is off", async () => {
  const { deps, logs } = fakeDeps({ sendConfirmation: () => Promise.resolve("off") });
  assertEquals((await handleWaitlist(post({ email: "a@example.com" }), deps)).status, 200);
  assertEquals(logs.length, 1);
  assertStringIncludes(logs[0], "email is off");
});

Deno.test("a failing mail provider is a retryable 500, with no address in the log", async () => {
  const { deps, logs } = fakeDeps({ sendConfirmation: () => Promise.reject(new Error("Resend answered 500")) });
  const response = await handleWaitlist(post({ email: "a@example.com" }), deps);
  assertEquals(response.status, 500);
  assertEquals(logs.some((line) => line.includes("a@example.com")), false);
});

Deno.test("only getfoon.com, www and localhost may post from a browser", async () => {
  const { deps } = fakeDeps();
  const evil = await handleWaitlist(post({ email: "a@example.com" }, { Origin: "https://evil.example" }), deps);
  assertEquals(evil.status, 403);
  assertEquals(evil.headers.get("Access-Control-Allow-Origin"), null);
  const preflight = await handleWaitlist(
    new Request("http://localhost/waitlist", { method: "OPTIONS", headers: { Origin: "http://localhost:3000" } }),
    deps,
  );
  assertEquals(preflight.status, 204);
  assertEquals(preflight.headers.get("Access-Control-Allow-Origin"), "http://localhost:3000");
});

Deno.test("a confirm link redirects to the site's confirmed page", async () => {
  const response = await handleWaitlist(new Request(`http://localhost/waitlist?confirm=${token}`), fakeDeps().deps);
  assertEquals(response.status, 303);
  assertEquals(response.headers.get("Location"), "https://getfoon.com/waitlist/confirmed");
});

Deno.test("expired, unknown and malformed confirm links land on the expired page", async () => {
  for (const outcome of ["expired", "invalid"] as const) {
    const { deps } = fakeDeps({}, "send", outcome);
    const response = await handleWaitlist(new Request(`http://localhost/waitlist?confirm=${token}`), deps);
    assertEquals(response.headers.get("Location"), "https://getfoon.com/waitlist/expired");
  }
  const malformed = await handleWaitlist(new Request("http://localhost/waitlist?confirm=short"), fakeDeps().deps);
  assertEquals(malformed.headers.get("Location"), "https://getfoon.com/waitlist/expired");
});

Deno.test("unsubscribe needs the signature, by link or by one-click POST", async () => {
  const { deps, unsubscribed } = fakeDeps();
  const good = `${id}.${await sign(id)}`;
  const link = await handleWaitlist(new Request(`http://localhost/waitlist?unsubscribe=${good}`), deps);
  assertEquals(link.headers.get("Location"), "https://getfoon.com/waitlist/unsubscribed");
  const forged = await handleWaitlist(new Request(`http://localhost/waitlist?unsubscribe=${id}.${"0".repeat(32)}`), deps);
  assertEquals(forged.headers.get("Location"), "https://getfoon.com/waitlist/expired");
  const oneClick = await handleWaitlist(
    new Request(`http://localhost/waitlist?unsubscribe=${good}`, { method: "POST", body: "List-Unsubscribe=One-Click" }),
    deps,
  );
  assertEquals(oneClick.status, 200);
  assertEquals(unsubscribed, [id, id]);
});

Deno.test("the confirmation email names the link, the offer, and how to unsubscribe", () => {
  const { text, html } = confirmationEmail({ firstName: "<b>Pat", confirmUrl: "https://x/c?confirm=t", unsubscribeUrl: "https://x/u" });
  assertStringIncludes(text, "https://x/c?confirm=t");
  assertStringIncludes(text, "Unsubscribe: https://x/u");
  assertStringIncludes(html, "&lt;b&gt;Pat");
});

Deno.test("Resend is called with a bearer key, and email stays off unless both settings exist", async () => {
  assertEquals(resendConfigFromEnv((key) => (key === "RESEND_API_KEY" ? "k" : undefined)), null);
  const config = resendConfigFromEnv((key) => ({ RESEND_API_KEY: "k", WAITLIST_FROM: "Foon <hello@getfoon.com>" })[key])!;
  let seen: { url: string; auth: string | null; to: string[] } | undefined;
  const fake = ((url: string, init: RequestInit) => {
    seen = {
      url,
      auth: new Headers(init.headers).get("Authorization"),
      to: JSON.parse(init.body as string).to,
    };
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as unknown as typeof fetch;
  await sendViaResend(config, "a@example.com", { firstName: null, confirmUrl: "c", unsubscribeUrl: "u" }, fake);
  assertEquals(seen, { url: "https://api.resend.com/emails", auth: "Bearer k", to: ["a@example.com"] });
  const failing = (() => Promise.resolve(new Response("no", { status: 422 }))) as unknown as typeof fetch;
  let threw = false;
  await sendViaResend(config, "a@example.com", { firstName: null, confirmUrl: "c", unsubscribeUrl: "u" }, failing)
    .catch(() => threw = true);
  assertEquals(threw, true);
});
