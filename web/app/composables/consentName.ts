// The kid's first name from the lookup, kept in memory for the next page only. It never goes in a URL, so a page
// opened directly (or reloaded) has none and words itself without it.
export const useConsentName = () => useState<string>("consent-first-name", () => "");

// Whether that link was a renewal (#277), so the next page words a renewal's answer: the kid stays signed out, or is
// back in. Like the name, in memory only; a page opened directly words itself without it.
export const useConsentRenewal = () => useState<boolean>("consent-renewal", () => false);

// For a renewal, whether the kid had signed in on their own device (#277): false words a No without "signed out". Null
// when unknown (an older server, or a page opened directly), which keeps the signed-out words.
export const useConsentWasLinked = () => useState<boolean | null>("consent-was-linked", () => null);
