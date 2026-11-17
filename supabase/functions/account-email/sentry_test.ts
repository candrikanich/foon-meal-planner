import { assertEquals, assertStrictEquals } from "@std/assert";
import { type ErrorReporter, REPORTING, scrubEvent, sentryEnvironment, withSentry } from "../_shared/sentry.ts";

Deno.test("sentryEnvironment maps hosted projects and ignores everything else", () => {
  assertEquals(sentryEnvironment("https://itnhdikhdsujklaimqqd.supabase.co"), "production");
  assertEquals(sentryEnvironment("https://cbftcssbnfdjjxoeflvj.supabase.co"), "staging");
  assertEquals(sentryEnvironment("http://kong:8000"), null);
  assertEquals(sentryEnvironment("http://127.0.0.1:54321"), null);
  assertEquals(sentryEnvironment(undefined), null);
});

Deno.test("scrubEvent redacts emails and drops request, user and extra", () => {
  const scrubbed = scrubEvent({
    message: "failed for mom@example.com",
    exception: { values: [{ type: "Error", value: "bounce from kid.name+x@mail.example.org" }, { type: "Error" }] },
    breadcrumbs: [{ message: "sent to a@b.co then c@d.io" }, { category: "x" }],
    request: { url: "https://x", headers: { authorization: "Bearer t" }, data: "body" },
    user: { id: "u1", email: "mom@example.com" },
    extra: { body: "secret" },
    type: undefined,
  });
  assertEquals(scrubbed.message, "failed for [email]");
  assertEquals(scrubbed.exception?.values?.[0].value, "bounce from [email]");
  assertEquals(scrubbed.exception?.values?.[1].value, undefined);
  assertEquals(scrubbed.breadcrumbs?.[0].message, "sent to [email] then [email]");
  assertEquals("request" in scrubbed, false);
  assertEquals("user" in scrubbed, false);
  assertEquals("extra" in scrubbed, false);
});

Deno.test("withSentry without a reporter returns the handler unchanged", async () => {
  const handler = () => new Response("ok");
  assertStrictEquals(withSentry("t", handler, null), handler);
  assertEquals(await (await withSentry("t", handler, null)(new Request("http://x"))).text(), "ok");
});

Deno.test("withSentry passes a response through without reporting", async () => {
  const captured: unknown[] = [];
  const reporter: ErrorReporter = { capture: (error) => Promise.resolve(void captured.push(error)) };
  const response = await withSentry("t", () => new Response("fine", { status: 201 }), reporter)(new Request("http://x"));
  assertEquals(response.status, 201);
  assertEquals(captured, []);
});

Deno.test("withSentry reports a thrown error and returns a plain 500", async () => {
  const captured: [unknown, string][] = [];
  const reporter: ErrorReporter = { capture: (error, name) => Promise.resolve(void captured.push([error, name])) };
  const boom = new Error("boom");
  const response = await withSentry("send-push", () => Promise.reject(boom), reporter)(new Request("http://x"));
  assertEquals(response.status, 500);
  assertEquals(await response.text(), "Internal Server Error");
  assertEquals(captured, [[boom, "send-push"]]);
});

Deno.test("production functions don't report until privacy v3 names Sentry", () => {
  assertEquals([...REPORTING], ["staging"]);
});
