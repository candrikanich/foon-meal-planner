import { describe, expect, it } from "vitest";
import { accountEmailEndpoint, unsubscribeEmail, unsubscribeKind } from "../app/utils/email";

const reply = (status: number, body: unknown = {}) =>
  (() => Promise.resolve(new Response(JSON.stringify(body), { status }))) as unknown as typeof fetch;

const token = "weekly_plan.a0000000-0000-0000-0000-00000000000a.0123456789abcdef0123456789abcdef";

describe("accountEmailEndpoint", () => {
  it("is the account-email function next to the waitlist one, so the site needs no new setting", () => {
    expect(accountEmailEndpoint("https://ref.supabase.co/functions/v1/waitlist")).toBe(
      "https://ref.supabase.co/functions/v1/account-email",
    );
    expect(accountEmailEndpoint("https://ref.supabase.co/functions/v1/waitlist/")).toBe(
      "https://ref.supabase.co/functions/v1/account-email",
    );
  });

  it("is empty when the site has no function URL (a preview build)", () => {
    expect(accountEmailEndpoint("")).toBe("");
    expect(accountEmailEndpoint("https://example.com/other")).toBe("");
  });
});

describe("unsubscribeKind", () => {
  it("reads which email a link is for", () => {
    expect(unsubscribeKind(token)).toBe("weekly_plan");
    expect(unsubscribeKind(token.replace("weekly_plan", "founding_updates"))).toBe("founding_updates");
  });

  it("is null for anything that isn't one of the links", () => {
    for (const value of ["", "weekly_plan", "newsletter.a.b", "weekly_plan.a", "weekly_plan.a.b.c"]) {
      expect(unsubscribeKind(value)).toBeNull();
    }
  });
});

describe("unsubscribeEmail", () => {
  it("POSTs the signed link only when the button is pressed", async () => {
    let seen: { url: string; method?: string } | undefined;
    const spy = ((url: string, init: RequestInit) => {
      seen = { url, method: init.method };
      return Promise.resolve(new Response(JSON.stringify({ ok: true })));
    }) as unknown as typeof fetch;
    expect(await unsubscribeEmail("https://f/account-email", token, spy)).toBe("done");
    expect(seen).toEqual({ url: `https://f/account-email?unsubscribe=${encodeURIComponent(token)}`, method: "POST" });
  });

  it("maps the function's answers", async () => {
    expect(await unsubscribeEmail("https://f", token, reply(400))).toBe("expired");
    expect(await unsubscribeEmail("https://f", token, reply(500))).toBe("error");
    expect(await unsubscribeEmail("", token, reply(200))).toBe("error");
    const offline = (() => Promise.reject(new TypeError("offline"))) as unknown as typeof fetch;
    expect(await unsubscribeEmail("https://f", token, offline)).toBe("error");
  });
});
