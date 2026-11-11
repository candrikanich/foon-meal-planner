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
