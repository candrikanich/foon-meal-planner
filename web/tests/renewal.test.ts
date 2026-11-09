import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { PRIVACY_VERSION, TERMS_VERSION } from "../app/content";
import { agreedDay, answerConsent, consentReply, nextPage, type PageState } from "../app/utils/consent";

// A renewal (#277): a kid whose consent was given to older wording is signed out until a parent agrees again.
const fn = "https://f/functions/v1/parental-consent";
const token = "abcDEF0123456789_-xyz";
const json = (body: unknown) =>
  (() => Promise.resolve(new Response(JSON.stringify(body), { status: 200 }))) as unknown as typeof fetch;
const renewalReply = {
  result: "pending",
  firstName: "Nora",
  expiresAt: "2026-11-15T00:00:00Z",
  reason: "renewal",
  summary: "Foon now confirms a parent's consent by email.",
  agreedBefore: "2026-10-01T12:00:00.123456+00:00",
};

describe("the renewal lookup schema", () => {
  it("accepts a renewal's reason, summary and agreedBefore, and a first consent without them", () => {
    expect(consentReply.safeParse(renewalReply).success).toBe(true);
    expect(consentReply.safeParse({ ...renewalReply, summary: null, agreedBefore: null }).success).toBe(true);
    expect(consentReply.safeParse({ result: "pending", firstName: "Nora", expiresAt: "x" }).success).toBe(true);
  });

  it("refuses an unknown reason, an empty summary or a non-text date", () => {
    expect(consentReply.safeParse({ ...renewalReply, reason: "upgrade" }).success).toBe(false);
    expect(consentReply.safeParse({ ...renewalReply, summary: "" }).success).toBe(false);
    expect(consentReply.safeParse({ ...renewalReply, agreedBefore: 5 }).success).toBe(false);
  });
});

describe("answerConsent for a renewal", () => {
  it("asks with what changed and when a parent agreed", async () => {
    expect(await answerConsent(fn, token, "lookup", json(renewalReply))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: { summary: renewalReply.summary, agreedBefore: renewalReply.agreedBefore },
    });
  });

  it("is still a renewal without the details, and a first consent has none", async () => {
    const bare = { result: "pending", firstName: "Nora", expiresAt: "x", reason: "renewal" };
    expect(await answerConsent(fn, token, "lookup", json(bare))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: { summary: null, agreedBefore: null },
    });
    const invite = { result: "pending", firstName: "Nora", expiresAt: "x", summary: "ignored" };
    expect(await answerConsent(fn, token, "lookup", json(invite))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: null,
    });
  });

  it("goes to the same answer pages as a first consent", async () => {
    expect(await answerConsent(fn, token, "refuse", json({ result: "refused" }))).toEqual({
      step: "go",
      to: "/consent/refused",
    });
    expect(await answerConsent(fn, token, "agree", json({ result: "confirmed" }))).toEqual({
      step: "go",
      to: "/consent/done",
    });
  });
});

describe("the renewal page state", () => {
  const renewal = { summary: "What changed.", agreedBefore: "2026-10-01T12:00:00Z" };

  it("keeps the renewal through a lookup and through a tap that doesn't finish", () => {
    const asking: PageState = { view: "ask", firstName: "Nora", renewal, notice: "none" };
    expect(nextPage({ view: "loading" }, { step: "ask", firstName: "Nora", renewal })).toEqual({ state: asking });
    expect(nextPage(asking, { step: "again" })).toEqual({ state: { ...asking, notice: "again" } });
    expect(nextPage(asking, { step: "error" })).toEqual({ state: { ...asking, notice: "problem" } });
  });

  it("words the date a parent agreed in UTC, and leaves out one that doesn't parse", () => {
    expect(agreedDay("2026-10-01T12:00:00.123456+00:00")).toBe("October 1, 2026");
    expect(agreedDay("2026-10-01T23:30:00-05:00")).toBe("October 2, 2026");
    expect(agreedDay("not a date")).toBeNull();
    expect(agreedDay(null)).toBeNull();
  });
});

describe("the renewal page's words", () => {
  const page = readFileSync(new URL("../app/pages/consent/index.vue", import.meta.url), "utf8");

  it("asks to keep using Foon, says what changed, and that No keeps the kid signed out with nothing deleted", () => {
    expect(page).toContain("Can ${state.firstName} keep using Foon?");
    expect(page).toContain(">What changed<");
    expect(page).toContain("No, keep ${state.firstName} signed out");
    expect(page).toContain("Nothing is");
    expect(page).toContain("To end your consent instead, withdraw it");
  });

  it("keeps the first consent's words for an invite", () => {
    expect(page).toContain("Can ${state.firstName} use Foon?");
    expect(page).toContain("No, don't invite ${state.firstName}");
  });
});

describe("Terms and Privacy version labels", () => {
  // Every registry row from every migration, so a label can't name a wording the database doesn't know.
  const migrations = new URL("../../supabase/migrations/", import.meta.url);
  const sql = readdirSync(migrations)
    .filter((file) => file.endsWith(".sql"))
    .map((file) => readFileSync(new URL(file, migrations), "utf8"))
    .join("\n");

  it("name registered wordings of their own kind", () => {
    expect(sql).toContain(`('${TERMS_VERSION}', 'terms',`);
    expect(sql).toContain(`('${PRIVACY_VERSION}', 'privacy',`);
  });

  it("are shown on /terms and /privacy", () => {
    const terms = readFileSync(new URL("../app/pages/terms.vue", import.meta.url), "utf8");
    const privacy = readFileSync(new URL("../app/pages/privacy.vue", import.meta.url), "utf8");
    expect(terms).toContain("{{ TERMS_VERSION }}");
    expect(privacy).toContain("{{ PRIVACY_VERSION }}");
  });
});
