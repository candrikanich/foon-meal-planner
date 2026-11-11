import { assert, assertStringIncludes } from "@std/assert";
import { POSTAL_ADDRESS, SENDER } from "../_shared/resend.ts";
import { deletionReceipt, type DeletionScope } from "./receipt.ts";

const scopes: DeletionScope[] = ["account", "account_and_household", "household"];

Deno.test("every receipt is transactional: sender, postal address, support address, no unsubscribe", () => {
  for (const scope of scopes) {
    const email = deletionReceipt(scope);
    for (const line of [SENDER, ...POSTAL_ADDRESS, "support@getfoon.com"]) {
      assertStringIncludes(email.text, line);
      assertStringIncludes(email.html, line);
    }
    assert(!email.text.toLowerCase().includes("unsubscribe"), scope);
    assert(!email.text.includes(String.fromCharCode(0x2014)), scope);
  }
});

Deno.test("each receipt says what was deleted and points at the privacy policy", () => {
  const account = deletionReceipt("account", "https://preview.example/");
  assertStringIncludes(account.subject, "account was deleted");
  assertStringIncludes(account.text, "Your sign-in and your profile are gone");
  assertStringIncludes(account.text, "https://preview.example/privacy");
  assertStringIncludes(account.text, "we won't send account email to this address again");

  const owner = deletionReceipt("account_and_household");
  assertStringIncludes(owner.text, "so is the household you owned");
  assertStringIncludes(owner.text, "https://getfoon.com/privacy");

  const household = deletionReceipt("household");
  assertStringIncludes(household.subject, "household was deleted");
  assertStringIncludes(household.text, "Your own account stays");
});
