import { describe, expect, it } from "vitest";
import { consentKept } from "../app/content";
import { answerConsent, answerWithdraw, CONSENT_ROUTES, nextPage, type PageState } from "../app/utils/consent";

const fn = "https://f/functions/v1/parental-consent";
const token = "abcDEF0123456789_-xyz";
const json = (status: number, body: unknown) =>
  (() => Promise.resolve(new Response(JSON.stringify(body), { status }))) as unknown as typeof fetch;
const never = (() => {
  throw new Error("should not call");
}) as unknown as typeof fetch;

describe("answerConsent", () => {
  it("POSTs the decision as JSON to ?consent=<token>", async () => {
    let seen: { url: string; method?: string; headers?: HeadersInit; body?: unknown } | undefined;
    const spy = ((url: string, init: RequestInit) => {
      seen = { url, method: init.method, headers: init.headers, body: JSON.parse(init.body as string) };
      return Promise.resolve(new Response(JSON.stringify({ result: "confirmed" })));
    }) as unknown as typeof fetch;
    await answerConsent(fn, token, "agree", spy);
    expect(seen).toEqual({
      url: `${fn}?consent=${token}`,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: { decision: "agree" },
    });
  });

  it("maps every result to its page", async () => {
    const pending = { result: "pending", firstName: "Nora", expiresAt: "2026-11-15T00:00:00Z" };
    expect(await answerConsent(fn, token, "lookup", json(200, pending))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: null,
    });
    expect(await answerConsent(fn, token, "agree", json(200, { result: "try_again" }))).toEqual({ step: "again" });
    expect(await answerConsent(fn, token, "agree", json(200, { result: "confirmed" }))).toEqual({
      step: "go",
      to: "/consent/done",
    });
    expect(await answerConsent(fn, token, "refuse", json(200, { result: "refused" }))).toEqual({
      step: "go",
      to: "/consent/refused",
    });
    for (const decision of ["lookup", "agree", "refuse"] as const) {
      expect(await answerConsent(fn, token, decision, json(200, { result: "already_consented" }))).toEqual({
        step: "go",
        to: "/consent/already",
      });
      expect(await answerConsent(fn, token, decision, json(200, { result: "withdrawn" }))).toEqual({
        step: "go",
        to: "/consent/withdrawn",
      });
    }
    for (const result of ["expired", "invalid"]) {
      expect(await answerConsent(fn, token, "lookup", json(200, { result }))).toEqual({
        step: "go",
        to: "/consent/expired",
      });
    }
  });

  it("says almost done only for I agree, and wait for a No mid-send", async () => {
    expect(await answerConsent(fn, token, "refuse", json(200, { result: "try_again" }))).toEqual({ step: "wait" });
    expect(await answerConsent(fn, token, "lookup", json(200, { result: "try_again" }))).toEqual({ step: "error" });
  });

  it("goes to expired without a token, and never calls out", async () => {
    expect(await answerConsent(fn, "", "lookup", never)).toEqual({ step: "go", to: "/consent/expired" });
  });

  it("is an error for failures, unknown answers and a missing endpoint", async () => {
    expect(await answerConsent(fn, token, "lookup", json(500, { error: "try_again" }))).toEqual({ step: "error" });
    expect(await answerConsent(fn, token, "lookup", json(400, { error: "bad_request" }))).toEqual({ step: "error" });
    expect(await answerConsent(fn, token, "lookup", json(403, { error: "forbidden" }))).toEqual({ step: "error" });
    expect(await answerConsent(fn, token, "lookup", json(200, { result: "surprise" }))).toEqual({ step: "error" });
    expect(await answerConsent(fn, token, "lookup", json(200, { result: "pending" }))).toEqual({ step: "error" });
    const offline = (() => Promise.reject(new TypeError("offline"))) as unknown as typeof fetch;
    expect(await answerConsent(fn, token, "agree", offline)).toEqual({ step: "error" });
    const notJson = (() => Promise.resolve(new Response("<html>", { status: 200 }))) as unknown as typeof fetch;
    expect(await answerConsent(fn, token, "agree", notJson)).toEqual({ step: "error" });
    expect(await answerConsent("", token, "lookup", never)).toEqual({ step: "error" });
  });
});

describe("answerWithdraw", () => {
  it("POSTs to ?withdraw=<token>", async () => {
    let seen: { url: string; body?: unknown } | undefined;
    const spy = ((url: string, init: RequestInit) => {
      seen = { url, body: JSON.parse(init.body as string) };
      return Promise.resolve(new Response(JSON.stringify({ result: "withdrawn" })));
    }) as unknown as typeof fetch;
    await answerWithdraw(fn, token, "withdraw", spy);
    expect(seen).toEqual({ url: `${fn}?withdraw=${token}`, body: { decision: "withdraw" } });
  });

  it("maps every result to its page", async () => {
    expect(await answerWithdraw(fn, token, "lookup", json(200, { result: "active", firstName: "Nora" }))).toEqual({
      step: "ask",
      firstName: "Nora",
    });
    expect(await answerWithdraw(fn, token, "withdraw", json(200, { result: "withdrawn" }))).toEqual({
      step: "go",
      to: "/consent/withdrawn",
    });
    for (const result of ["expired", "invalid"]) {
      expect(await answerWithdraw(fn, token, "withdraw", json(200, { result }))).toEqual({
        step: "go",
        to: "/consent/expired?link=withdraw",
      });
    }
  });

  it("goes to the withdraw expired page without a token, and errors otherwise", async () => {
    expect(await answerWithdraw(fn, "", "lookup", never)).toEqual({ step: "go", to: "/consent/expired?link=withdraw" });
    expect(await answerWithdraw(fn, token, "lookup", json(500, {}))).toEqual({ step: "error" });
    expect(await answerWithdraw(fn, token, "lookup", json(200, { result: "pending" }))).toEqual({ step: "error" });
    expect(await answerWithdraw("", token, "lookup", never)).toEqual({ step: "error" });
  });
});

describe("page states", () => {
  const loading: PageState = { view: "loading" };
  const asking: PageState = { view: "ask", firstName: "Nora", renewal: null, notice: "none" };

  it("shows the buttons after a lookup finds the request", () => {
    expect(nextPage(loading, { step: "ask", firstName: "Nora" })).toEqual({ state: asking });
    expect(nextPage({ view: "unreachable" }, { step: "ask", firstName: "Nora" })).toEqual({ state: asking });
  });

  it("navigates for every final answer", () => {
    for (const to of Object.values(CONSENT_ROUTES)) {
      expect(nextPage(asking, { step: "go", to })).toEqual({ navigate: to });
      expect(nextPage(loading, { step: "go", to })).toEqual({ navigate: to });
    }
  });

  it("says unreachable when the lookup fails, and lets it be retried", () => {
    expect(nextPage(loading, { step: "error" })).toEqual({ state: { view: "unreachable" } });
    expect(nextPage({ view: "unreachable" }, { step: "error" })).toEqual({ state: { view: "unreachable" } });
  });

  it("keeps the buttons with a note when a tap doesn't finish", () => {
    expect(nextPage(asking, { step: "again" })).toEqual({ state: { ...asking, notice: "again" } });
    expect(nextPage(asking, { step: "error" })).toEqual({ state: { ...asking, notice: "problem" } });
  });

  it("sends an already-agreed or withdrawn consent link to its own page, never done", () => {
    for (const current of [loading, asking]) {
      expect(nextPage(current, { step: "go", to: CONSENT_ROUTES.already })).toEqual({ navigate: "/consent/already" });
      expect(nextPage(current, { step: "go", to: CONSENT_ROUTES.withdrawn })).toEqual({
        navigate: "/consent/withdrawn",
      });
    }
  });

  it("keeps the parent on the page when No lands while an I agree is sending", () => {
    expect(nextPage(asking, { step: "wait" })).toEqual({ state: { ...asking, notice: "wait" } });
    expect(nextPage({ ...asking, notice: "wait" }, { step: "go", to: CONSENT_ROUTES.refused })).toEqual({
      navigate: "/consent/refused",
    });
    expect(nextPage({ ...asking, notice: "again" }, { step: "ask", firstName: "Nora" })).toEqual({ state: asking });
  });

  it("never puts the name in a route", () => {
    for (const to of Object.values(CONSENT_ROUTES)) expect(to).not.toMatch(/name|Nora/i);
  });
});

describe("the consent notice", () => {
  it("lists what the email lists, with the kid's name", () => {
    const kept = consentKept("Nora").join(" ");
    for (const word of ["first name", "avatar", "allergies", "schedule", "requests", "age range", "Apple sign-in"]) {
      expect(kept).toContain(word);
    }
    expect(kept).toContain("never a birthdate");
    expect(kept).toContain("Nora");
  });
});
