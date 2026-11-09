import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { PRIVACY_VERSION, TERMS_VERSION } from "../app/content";
import { agreedDay, answerConsent, consentReply, nextPage, renewalWords, type PageState } from "../app/utils/consent";

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
    expect(consentReply.safeParse({ ...renewalReply, wasLinked: false }).success).toBe(true);
    expect(consentReply.safeParse({ ...renewalReply, wasLinked: null }).success).toBe(true);
    expect(consentReply.safeParse({ result: "pending", firstName: "Nora", expiresAt: "x" }).success).toBe(true);
  });

  it("refuses an unknown reason, an empty summary or a non-text date", () => {
    expect(consentReply.safeParse({ ...renewalReply, reason: "upgrade" }).success).toBe(false);
    expect(consentReply.safeParse({ ...renewalReply, summary: "" }).success).toBe(false);
    expect(consentReply.safeParse({ ...renewalReply, agreedBefore: 5 }).success).toBe(false);
    expect(consentReply.safeParse({ ...renewalReply, wasLinked: "no" }).success).toBe(false);
  });
});

describe("answerConsent for a renewal", () => {
  it("asks with what changed and when a parent agreed", async () => {
    expect(await answerConsent(fn, token, "lookup", json(renewalReply))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: { summary: renewalReply.summary, agreedBefore: renewalReply.agreedBefore, wasLinked: null },
    });
    expect(await answerConsent(fn, token, "lookup", json({ ...renewalReply, wasLinked: false }))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: { summary: renewalReply.summary, agreedBefore: renewalReply.agreedBefore, wasLinked: false },
    });
  });

  it("is still a renewal without the details, and a first consent has none", async () => {
    const bare = { result: "pending", firstName: "Nora", expiresAt: "x", reason: "renewal" };
    expect(await answerConsent(fn, token, "lookup", json(bare))).toEqual({
      step: "ask",
      firstName: "Nora",
      renewal: { summary: null, agreedBefore: null, wasLinked: null },
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
  const renewal = { summary: "What changed.", agreedBefore: "2026-10-01T12:00:00Z", wasLinked: true };

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
    expect(page).toContain("words.refuseButton");
    expect(page).toContain("Nothing is");
    expect(page).toContain("To end your consent instead, withdraw it");
  });

  it("keeps the first consent's words for an invite", () => {
    expect(page).toContain("Can ${state.firstName} use Foon?");
    expect(page).toContain("No, don't invite ${state.firstName}");
  });
});

describe("a renewal's words for where the kid stands", () => {
  it("say signed out for a kid who had signed in, or when the server didn't say", () => {
    for (const wasLinked of [true, null]) {
      expect(renewalWords("Nora", wasLinked)).toEqual({
        until: "Until a parent agrees, Nora is signed out of Foon.",
        ifNo: "If you say no, Nora stays signed out and Foon collects nothing new from them.",
        refuseButton: "No, keep Nora signed out",
        refused: "Nora stays signed out of Foon. Nothing is deleted.",
      });
    }
  });

  it("never say signed out for a kid who never signed in on their own device", () => {
    const words = renewalWords("Nora", false);
    expect(Object.values(words).some((line) => line.includes("signed out"))).toBe(false);
    expect(words.until).toBe("Until a parent agrees, Nora can't use Foon on their own device.");
    expect(words.refuseButton).toBe("No, don't let Nora use Foon");
    expect(words.refused).toBe("Nora still can't use Foon on their own device. Nothing is deleted.");
  });

  it("word /consent/refused without a name when the page was opened directly", () => {
    expect(renewalWords("", false).refused).toBe(
      "Your kid still can't use Foon on their own device. Nothing is deleted.",
    );
    expect(renewalWords("", null).refused).toBe("Your kid stays signed out of Foon. Nothing is deleted.");
  });

  it("are what /consent and /consent/refused show", () => {
    const page = readFileSync(new URL("../app/pages/consent/index.vue", import.meta.url), "utf8");
    const refused = readFileSync(new URL("../app/pages/consent/refused.vue", import.meta.url), "utf8");
    expect(page).toContain("renewalWords(state.value.firstName, state.value.renewal.wasLinked)");
    expect(page).toContain("{{ words?.until }}");
    expect(page).toContain("{{ words?.ifNo }}");
    expect(page).not.toContain("is signed out of Foon");
    expect(refused).toContain("renewalWords(name, wasLinked).refused");
    expect(refused).not.toContain("stays signed out");
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
