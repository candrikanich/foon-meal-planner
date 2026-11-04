import { assertEquals, assertStringIncludes } from "@std/assert";
import { callerAddress, clientKey, networkOf, safeEqual } from "./client.ts";
import { sha256, signer } from "./crypto.ts";
import {
  confirmationEmail,
  resendConfigFromEnv,
  sendViaResend,
} from "./email.ts";
import {
  type ConfirmOutcome,
  handleWaitlist,
  type JoinResult,
  type WaitlistDeps,
} from "./handler.ts";

const id = "11111111-2222-3333-4444-555555555555";
const sign = signer("service-key");
const token = "t".repeat(43);
const send: JoinResult = { outcome: "send", signupId: id, attemptId: 7 };

function fakeDeps(
  overrides: Partial<WaitlistDeps> = {},
  join: JoinResult = send,
  confirm: ConfirmOutcome = "confirmed",
) {
  const joins: Array<
    { email: string; firstName: string | null; ipHash: string }
  > = [];
  const marked: Array<
    {
      signupId: string;
      attemptId: number;
      tokenHash: string;
      firstName: string | null;
    }
  > = [];
  const sent: Array<
    { to: string; confirmUrl: string; unsubscribeUrl: string }
  > = [];
  const logs: string[] = [];
  const unsubscribed: string[] = [];
  const confirmed: string[] = [];
  const background: Promise<unknown>[] = [];
  const deps: WaitlistDeps = {
    allowedOrigins: ["https://getfoon.com", "http://localhost:3000"],
    siteUrl: "https://getfoon.com",
    functionUrl: "https://x.supabase.co/functions/v1/waitlist",
    join: (input) => {
      joins.push(input);
      return Promise.resolve(join);
    },
    markSent: (input) => {
      marked.push(input);
      return Promise.resolve();
    },
    confirm: (tokenHash) => {
      confirmed.push(tokenHash);
      return Promise.resolve(confirm);
    },
    unsubscribe: (target) => {
      unsubscribed.push(target);
      return Promise.resolve();
    },
    newToken: () => token,
    sha256,
    sign,
    sendConfirmation: (message) => {
      sent.push(message);
      return Promise.resolve("sent");
    },
    defer: (work) => background.push(work),
    log: (message) => logs.push(message),
    ...overrides,
  };
  return {
    deps,
    joins,
    marked,
    sent,
    logs,
    unsubscribed,
    confirmed,
    settle: () => Promise.all(background),
  };
}

const post = (body: unknown, headers: Record<string, string> = {}, path = "") =>
  new Request(`http://localhost/waitlist${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: "https://getfoon.com",
      ...headers,
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

Deno.test("a signup answers without waiting for the email, which is marked sent only once it has gone out", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => release = resolve);
  const base = fakeDeps();
  const { deps, joins, marked, sent, settle } = fakeDeps({
    sendConfirmation: async (message) => {
      await gate;
      return base.deps.sendConfirmation(message).then((result) => {
        sent.push(message);
        return result;
      });
    },
  });
  const response = await handleWaitlist(
    post({ email: " Pat@Example.com ", firstName: "Pat" }, {
      "cf-connecting-ip": "5.6.7.8",
    }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { ok: true });
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    "https://getfoon.com",
  );
  assertEquals(joins[0], {
    email: "Pat@Example.com",
    firstName: "Pat",
    ipHash: await sign("ip:5.6.7.8"),
  });
  assertEquals(
    marked.length,
    0,
    "answered while the email was still in flight, and nothing is marked yet",
  );
  release();
  await settle();
  assertEquals(
    sent[0].confirmUrl,
    `https://x.supabase.co/functions/v1/waitlist?confirm=${token}`,
  );
  assertStringIncludes(
    sent[0].unsubscribeUrl,
    `?unsubscribe=${id}.${await sign(id)}`,
  );
  assertEquals(marked, [{
    signupId: id,
    attemptId: 7,
    tokenHash: await sha256(token),
    firstName: "Pat",
  }]);
  assertEquals(marked[0].tokenHash === token, false);
});

Deno.test("a failed send is not marked, so a retry sends and the cap isn't filled", async () => {
  const { deps, marked, logs, settle } = fakeDeps({
    sendConfirmation: () => Promise.reject(new Error("Resend answered 500")),
  });
  const response = await handleWaitlist(post({ email: "a@example.com" }), deps);
  assertEquals(response.status, 200);
  await settle();
  assertEquals(marked.length, 0);
  assertEquals(logs.some((line) => line.includes("a@example.com")), false);
});

Deno.test("the answer is the same whether or not the email was already here", async () => {
  const fresh = fakeDeps({}, send);
  const known = fakeDeps({}, { outcome: "skip" });
  const a = await handleWaitlist(post({ email: "a@example.com" }), fresh.deps);
  const b = await handleWaitlist(post({ email: "a@example.com" }), known.deps);
  assertEquals([a.status, await a.text()], [b.status, await b.text()]);
  await known.settle();
  assertEquals(known.sent.length, 0);
});

Deno.test("a filled honeypot looks like success and stores nothing", async () => {
  const { deps, joins, sent, settle } = fakeDeps();
  const response = await handleWaitlist(
    post({ email: "bot@example.com", website: "http://spam" }),
    deps,
  );
  assertEquals(response.status, 200);
  await settle();
  assertEquals(joins.length + sent.length, 0);
});

Deno.test("bad emails, names and bodies are 400", async () => {
  const { deps, joins } = fakeDeps();
  const names = [
    "x".repeat(41),
    "Pat http://evil.example",
    "Pat <b>",
    "Pat1",
    "-Pat",
    "Pat\nClick here",
  ];
  for (
    const body of [
      { email: "nope" },
      {},
      ...names.map((firstName) => ({ email: "a@b.co", firstName })),
      "not json",
    ]
  ) {
    assertEquals((await handleWaitlist(post(body), deps)).status, 400);
  }
  assertEquals(joins.length, 0);
});

Deno.test("names with letters from any language, hyphens and apostrophes are fine", async () => {
  for (const firstName of ["Zoë", "Mary-Jane", "O'Brien", "Åsa", "李雷", ""]) {
    const { deps, joins } = fakeDeps();
    assertEquals(
      (await handleWaitlist(post({ email: "a@example.com", firstName }), deps))
        .status,
      200,
    );
    assertEquals(joins[0].firstName, firstName || null);
  }
});

Deno.test("the rate limit is a 429 and sends nothing", async () => {
  const { deps, sent, settle } = fakeDeps({}, { outcome: "rate_limited" });
  assertEquals(
    (await handleWaitlist(post({ email: "a@example.com" }), deps)).status,
    429,
  );
  await settle();
  assertEquals(sent.length, 0);
});

Deno.test("without email configured the signup still succeeds, nothing is marked sent, and the log says email is off", async () => {
  const { deps, logs, marked, settle } = fakeDeps({
    sendConfirmation: () => Promise.resolve("off"),
  });
  assertEquals(
    (await handleWaitlist(post({ email: "a@example.com" }), deps)).status,
    200,
  );
  await settle();
  assertEquals(marked.length, 0);
  assertEquals(logs.length, 1);
  assertStringIncludes(logs[0], "email is off");
});

Deno.test("a storage failure is a retryable 500", async () => {
  const { deps } = fakeDeps({
    join: () => Promise.reject(new Error("db down")),
  });
  assertEquals(
    (await handleWaitlist(post({ email: "a@example.com" }), deps)).status,
    500,
  );
});

Deno.test("only getfoon.com, www and localhost may post from a browser", async () => {
  const { deps } = fakeDeps();
  const evil = await handleWaitlist(
    post({ email: "a@example.com" }, { Origin: "https://evil.example" }),
    deps,
  );
  assertEquals(evil.status, 403);
  assertEquals(evil.headers.get("Access-Control-Allow-Origin"), null);
  const preflight = await handleWaitlist(
    new Request("http://localhost/waitlist", {
      method: "OPTIONS",
      headers: { Origin: "http://localhost:3000" },
    }),
    deps,
  );
  assertEquals(preflight.status, 204);
  assertEquals(
    preflight.headers.get("Access-Control-Allow-Origin"),
    "http://localhost:3000",
  );
});

Deno.test("GET on a confirm link only redirects to the site's page, touching nothing", async () => {
  const { deps, confirmed, unsubscribed } = fakeDeps();
  const response = await handleWaitlist(
    new Request(`http://localhost/waitlist?confirm=${token}`),
    deps,
  );
  assertEquals(response.status, 303);
  assertEquals(
    response.headers.get("Location"),
    `https://getfoon.com/waitlist/confirm?t=${token}`,
  );
  const malformed = await handleWaitlist(
    new Request("http://localhost/waitlist?confirm=short"),
    deps,
  );
  assertEquals(
    malformed.headers.get("Location"),
    "https://getfoon.com/waitlist/expired",
  );
  const link = await handleWaitlist(
    new Request(`http://localhost/waitlist?unsubscribe=${id}.abc`),
    deps,
  );
  assertEquals(
    link.headers.get("Location"),
    `https://getfoon.com/waitlist/unsubscribe?u=${id}.abc`,
  );
  assertEquals(confirmed.length + unsubscribed.length, 0);
});

Deno.test("POST confirms, and says expired or invalid when it can't", async () => {
  for (const outcome of ["confirmed", "expired", "invalid"] as const) {
    const { deps, confirmed } = fakeDeps({}, send, outcome);
    const response = await handleWaitlist(
      post("", {}, `?confirm=${token}`),
      deps,
    );
    assertEquals(await response.json(), { result: outcome });
    assertEquals(confirmed, [await sha256(token)]);
  }
  const { deps, confirmed } = fakeDeps();
  assertEquals(
    await (await handleWaitlist(post("", {}, "?confirm=short"), deps)).json(),
    { result: "invalid" },
  );
  assertEquals(confirmed.length, 0);
});

Deno.test("unsubscribe needs the signature, from the site's page or a mail client's one-click POST", async () => {
  const { deps, unsubscribed } = fakeDeps();
  const good = `${id}.${await sign(id)}`;
  const fromSite = await handleWaitlist(
    post("", {}, `?unsubscribe=${good}`),
    deps,
  );
  assertEquals(fromSite.status, 200);
  const oneClick = await handleWaitlist(
    new Request(`http://localhost/waitlist?unsubscribe=${good}`, {
      method: "POST",
      body: "List-Unsubscribe=One-Click",
    }),
    deps,
  );
  assertEquals(oneClick.status, 200);
  assertEquals(unsubscribed, [id, id]);
  const forged = await handleWaitlist(
    post("", {}, `?unsubscribe=${id}.${"0".repeat(32)}`),
    deps,
  );
  assertEquals(forged.status, 400);
  assertEquals(unsubscribed.length, 2);
});

Deno.test("the confirmation email says what's kept, and nothing the signer typed is in it", () => {
  const { text, html } = confirmationEmail({
    confirmUrl: "https://x/c?confirm=t",
    unsubscribeUrl: "https://x/u",
  });
  assertStringIncludes(text, "https://x/c?confirm=t");
  assertStringIncludes(text, "30 days after this email goes out");
  assertStringIncludes(text, "deletes your address right away): https://x/u");
  assertStringIncludes(html, "<p>Hi,</p>");
});

Deno.test("Resend is called with a bearer key and the one-click headers, and email stays off unless both settings exist", async () => {
  assertEquals(
    resendConfigFromEnv((key) => (key === "RESEND_API_KEY" ? "k" : undefined)),
    null,
  );
  const config = resendConfigFromEnv((key) =>
    ({ RESEND_API_KEY: "k", WAITLIST_FROM: "Foon <hello@getfoon.com>" })[key]
  )!;
  let seen:
    | { url: string; auth: string | null; to: string[]; oneClick: string }
    | undefined;
  const fake = ((url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string);
    seen = {
      url,
      auth: new Headers(init.headers).get("Authorization"),
      to: body.to,
      oneClick: body.headers["List-Unsubscribe-Post"],
    };
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as unknown as typeof fetch;
  await sendViaResend(config, "a@example.com", {
    confirmUrl: "c",
    unsubscribeUrl: "u",
  }, fake);
  assertEquals(seen, {
    url: "https://api.resend.com/emails",
    auth: "Bearer k",
    to: ["a@example.com"],
    oneClick: "List-Unsubscribe=One-Click",
  });
  const failing = (() =>
    Promise.resolve(
      new Response("no", { status: 422 }),
    )) as unknown as typeof fetch;
  let threw = false;
  await sendViaResend(config, "a@example.com", {
    confirmUrl: "c",
    unsubscribeUrl: "u",
  }, failing).catch(() => threw = true);
  assertEquals(threw, true);
});

Deno.test("the caller's address comes from cf-connecting-ip, else the last forwarded hop, never the first", () => {
  assertEquals(
    callerAddress(
      new Headers({
        "cf-connecting-ip": "9.9.9.9",
        "x-forwarded-for": "6.6.6.6, 1.1.1.1",
      }),
    ),
    "9.9.9.9",
  );
  assertEquals(
    callerAddress(new Headers({ "x-forwarded-for": "6.6.6.6, 1.1.1.1" })),
    "1.1.1.1",
  );
  assertEquals(
    callerAddress(new Headers({ "x-real-ip": "2.2.2.2" })),
    "unknown",
  );
  assertEquals(callerAddress(new Headers()), "unknown");
});

Deno.test("IPv6 addresses are limited by their /64", () => {
  assertEquals(networkOf("203.0.113.9"), "203.0.113.9");
  assertEquals(
    networkOf("2001:db8:abcd:12:aaaa:bbbb:cccc:dddd"),
    "2001:db8:abcd:12::/64",
  );
  assertEquals(
    networkOf("2001:DB8:abcd:12:1::1"),
    networkOf("2001:db8:abcd:12:ffff::2"),
  );
  assertEquals(networkOf("2001:db8::1"), "2001:db8:0:0::/64");
  assertEquals(networkOf("::1"), "0:0:0:0::/64");
  assertEquals(networkOf("::ffff:203.0.113.9"), "203.0.113.9");
  assertEquals(
    clientKey(new Headers({ "cf-connecting-ip": "2001:db8:1:2:3:4:5:6" })),
    clientKey(new Headers({ "cf-connecting-ip": "2001:db8:1:2:ffff::1" })),
  );
});

Deno.test("safeEqual compares whole strings", () => {
  assertEquals(safeEqual("abc", "abc"), true);
  assertEquals(safeEqual("abc", "abd"), false);
  assertEquals(safeEqual("abc", "abcd"), false);
});
