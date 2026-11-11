import type { ActionResult } from "./waitlist";

// The emails an adult turns on in Foon (#48): their unsubscribe links open /email/unsubscribe.
export type OptInEmail = "weekly_plan" | "founding_updates";

// The account-email function lives next to the waitlist function, so its URL comes from NUXT_PUBLIC_WAITLIST_URL and the
// site needs no new build setting. Empty when there's no waitlist URL (a preview build), like the forms.
export function accountEmailEndpoint(waitlistUrl: string): string {
  const match = waitlistUrl.match(/^(.*\/functions\/v1\/)waitlist\/?$/);
  return match ? `${match[1]}account-email` : "";
}

// Which email a link is for: "<kind>.<account>.<signature>". The function checks the signature; this only picks the words.
export function unsubscribeKind(token: string): OptInEmail | null {
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((part) => !part)) return null;
  return parts[0] === "weekly_plan" || parts[0] === "founding_updates" ? parts[0] : null;
}

// Runs only when the person presses the page's button: mail scanners open every link in a message.
export async function unsubscribeEmail(endpoint: string, token: string, post: typeof fetch = fetch): Promise<ActionResult> {
  if (!endpoint) return "error";
  try {
    const response = await post(`${endpoint}?unsubscribe=${encodeURIComponent(token)}`, { method: "POST" });
    if (response.ok) return "done";
    return response.status === 400 ? "expired" : "error";
  } catch {
    return "error";
  }
}
