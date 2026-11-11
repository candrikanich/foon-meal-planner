// "Your Foon account was deleted" (#48): sent once a deletion has fully gone through, to the Apple email of the adult
// who asked for it. Transactional: the sender, postal address and support address, no unsubscribe link. No value from
// the family goes in it.
import { SUPPORT_EMAIL, transactionalEmail } from "../_shared/email_layout.ts";
import type { Email } from "../_shared/resend.ts";

export const DEFAULT_SITE_URL = "https://getfoon.com";

// What was deleted: an account (and with it the household its owner had), or only a household.
export type DeletionScope = "account" | "account_and_household" | "household";

export function deletionReceipt(scope: DeletionScope, siteUrl = DEFAULT_SITE_URL): Omit<Email, "to"> {
  const privacy = `${siteUrl.replace(/\/+$/, "")}/privacy`;
  const questions = `Questions? Write to ${SUPPORT_EMAIL}.`;
  const nothingKept = "We don't keep a copy of what was deleted, and we won't send account email to this address " +
    "again. The only " +
    `records we keep are the ones our privacy policy lists: ${privacy}`;
  switch (scope) {
    case "household":
      return transactionalEmail("Your Foon household was deleted", [
        "Hi,",
        "You deleted your household in Foon. Everything in it is gone, for everyone in it: its people, plans, dishes, " +
        "dinners, lists and photos.",
        "Your own account stays, so you can start or join a household in Foon whenever you like.",
        `We don't keep a copy of what was deleted. The only records we keep are the ones our privacy policy lists: ` +
        privacy,
        questions,
      ]);
    case "account_and_household":
      return transactionalEmail("Your Foon account was deleted", [
        "Hi,",
        "You deleted your Foon account. Your sign-in is gone, and so is the household you owned, with everything in " +
        "it, for everyone in it: its people, plans, dishes, dinners, lists and photos.",
        nothingKept,
        questions,
      ]);
    case "account":
      return transactionalEmail("Your Foon account was deleted", [
        "Hi,",
        "You deleted your Foon account. Your sign-in and your profile are gone. Your family's plans, dishes and lists " +
        "stay with them, without your name.",
        nothingKept,
        questions,
      ]);
  }
}
