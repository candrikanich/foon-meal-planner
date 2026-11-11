import { assert, assertEquals } from "@std/assert";
import {
  handleUnsubscribe,
  readUnsubscribeToken,
  unsubscribeLinks,
  type UnsubscribeDeps,
} from "./unsubscribe.ts";

const user = "a0000000-0000-0000-0000-00000000000a";
const links = unsubscribeLinks("service-secret", "https://x.supabase.co/functions/v1/account-email");

Deno.test("a link names the email and the person, and carries a signature", async () => {
  const url = new URL(await links.url("weekly_plan", user));
  assertEquals(url.origin + url.pathname, "https://x.supabase.co/functions/v1/account-email");
  const token = url.searchParams.get("unsubscribe")!;
  assertEquals(token.split(".").slice(0, 2), ["weekly_plan", user]);
  assertEquals(await readUnsubscribeToken(token, links.sign), { kind: "weekly_plan", userId: user });
});

Deno.test("a signature works only for its own email, person and secret", async () => {
  const token = new URL(await links.url("weekly_plan", user)).searchParams.get("unsubscribe")!;
  const signature = token.split(".")[2];
  const other = "b0000000-0000-0000-0000-00000000000b";
  assertEquals(await readUnsubscribeToken(`founding_updates.${user}.${signature}`, links.sign), null,
    "one email's link can't unsubscribe from the other");
  assertEquals(await readUnsubscribeToken(`weekly_plan.${other}.${signature}`, links.sign), null);
  const elsewhere = unsubscribeLinks("another-secret", "https://x");
  assertEquals(await readUnsubscribeToken(token, elsewhere.sign), null);
  for (const bad of ["", "weekly_plan", `weekly_plan.${user}`, `newsletter.${user}.${signature}`, `weekly_plan.nope.${signature}`]) {
    assertEquals(await readUnsubscribeToken(bad, links.sign), null, bad);
  }
});

function fakeDeps(overrides: Partial<UnsubscribeDeps> = {}) {
  const done: string[] = [];
  const deps: UnsubscribeDeps = {
    allowedOrigins: ["https://getfoon.com"],
    siteUrl: "https://getfoon.com",
    sign: links.sign,
    unsubscribe: (userId, kind) => {
      done.push(`${kind} ${userId}`);
      return Promise.resolve();
    },
    log: () => {},
    ...overrides,
  };
  return { deps, done };
}

const tokenFor = async (kind: "weekly_plan" | "founding_updates") =>
  new URL(await links.url(kind, user)).searchParams.get("unsubscribe")!;

const request = (token: string, method: string, headers: Record<string, string> = {}, body?: string) =>
  new Request(`https://x.supabase.co/functions/v1/account-email?unsubscribe=${encodeURIComponent(token)}`, {
    method,
    headers,
    body,
  });

Deno.test("opening the link changes nothing: it goes to the site's page, whose button does it", async () => {
  const { deps, done } = fakeDeps();
  const token = await tokenFor("weekly_plan");
  const response = await handleUnsubscribe(request(token, "GET"), token, deps);
  assertEquals(response.status, 303);
  assertEquals(response.headers.get("Location"), `https://getfoon.com/email/unsubscribe?u=${encodeURIComponent(token)}`);
  assertEquals(done, []);
});

Deno.test("the site's button turns that email off", async () => {
  const { deps, done } = fakeDeps();
  const token = await tokenFor("founding_updates");
  const response = await handleUnsubscribe(request(token, "POST", { Origin: "https://getfoon.com" }), token, deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { ok: true, kind: "founding_updates" });
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://getfoon.com");
  assertEquals(done, [`founding_updates ${user}`]);
});

Deno.test("a mail app's one-click POST (no Origin) does too", async () => {
  const { deps, done } = fakeDeps();
  const token = await tokenFor("weekly_plan");
  const response = await handleUnsubscribe(
    request(token, "POST", { "Content-Type": "application/x-www-form-urlencoded" }, "List-Unsubscribe=One-Click"),
    token,
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(done, [`weekly_plan ${user}`]);
});

Deno.test("a bad signature, another site, or another method changes nothing", async () => {
  const { deps, done } = fakeDeps();
  const token = await tokenFor("weekly_plan");
  const forged = token.replace(/.$/, (c) => (c === "0" ? "1" : "0"));
  assertEquals((await handleUnsubscribe(request(forged, "POST"), forged, deps)).status, 400);
  assertEquals((await handleUnsubscribe(request(token, "POST", { Origin: "https://evil.example" }), token, deps)).status,
    403);
  assertEquals((await handleUnsubscribe(request(token, "PUT"), token, deps)).status, 405);
  assertEquals(done, []);
});

Deno.test("the site's preflight is answered", async () => {
  const { deps } = fakeDeps();
  const token = await tokenFor("weekly_plan");
  const response = await handleUnsubscribe(request(token, "OPTIONS", { Origin: "https://getfoon.com" }), token, deps);
  assertEquals(response.status, 204);
  assertEquals(response.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
});

Deno.test("a database failure says try again, and logs no address or id", async () => {
  const logs: string[] = [];
  const { deps } = fakeDeps({
    unsubscribe: () => Promise.reject(new Error("db down")),
    log: (message, detail) => logs.push(`${message} ${detail ?? ""}`),
  });
  const token = await tokenFor("weekly_plan");
  const response = await handleUnsubscribe(request(token, "POST"), token, deps);
  assertEquals(response.status, 500);
  assert(logs.every((line) => !line.includes(user)));
});
