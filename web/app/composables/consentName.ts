// The kid's first name from the lookup, kept in memory for the next page only. It never goes in a URL, so a page
// opened directly (or reloaded) has none and words itself without it.
export const useConsentName = () => useState<string>("consent-first-name", () => "");
