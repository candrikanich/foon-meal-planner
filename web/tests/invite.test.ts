import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { inviteCode } from "../app/utils/invite";

describe("inviteCode", () => {
  it("keeps a code as the app made it", () => {
    expect(inviteCode("ANDRI-7KQ4-M9XP")).toBe("ANDRI-7KQ4-M9XP");
  });

  it("uppercases and trims what a mail app or a person did to it", () => {
    expect(inviteCode(" andri-7kq4-m9xp ")).toBe("ANDRI-7KQ4-M9XP");
  });

  it.each([undefined, null, "", "   ", ["ANDRI-7KQ4-M9XP"], "<script>", "ANDRI-7KQ4-M9XP-ANDRI-7KQ4-M9XP"])(
    "shows no code for %j",
    (value) => {
      expect(inviteCode(value)).toBeNull();
    },
  );
});

// Foon and Foon QA (docs/foon-qa.md) each get their own invite path, so a phone with both opens the right one.
describe("apple-app-site-association", () => {
  type Detail = { appIDs: string[]; components: { "/": string }[] };
  const file = new URL("../public/.well-known/apple-app-site-association", import.meta.url);
  const details: Detail[] = JSON.parse(readFileSync(file, "utf8")).applinks.details;
  // Apple's path patterns match the whole path: `*` is any run of characters, `?` one character.
  const matches = (pattern: string, path: string) => {
    const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
    return new RegExp(`^${escaped}$`).test(path);
  };
  const appsFor = (path: string) =>
    details.filter((d) => d.components.some((c) => matches(c["/"], path))).flatMap((d) => d.appIDs);

  it.each([
    ["/invite", ["G374A783RH.com.andrikanich.foon"]],
    ["/qa/invite", ["G374A783RH.com.andrikanich.foon.qa"]],
    ["/privacy", []],
    ["/qa/invite/extra", []],
  ])("opens %s in %j", (path, apps) => {
    expect(appsFor(path)).toEqual(apps);
  });
});
