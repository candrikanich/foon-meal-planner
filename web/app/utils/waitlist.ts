import { z } from "zod";

export const waitlistSchema = z.object({
  email: z.string().trim().max(254).pipe(z.email()),
  firstName: z.string().trim().max(60).optional(),
});

export type WaitlistInput = z.input<typeof waitlistSchema> & { website?: string };

// "unavailable" is a site with no function URL configured (a preview build); the rest map to what the form says.
export type WaitlistResult = "ok" | "invalid" | "slow_down" | "error" | "unavailable";

export async function submitWaitlist(
  endpoint: string,
  input: WaitlistInput,
  post: typeof fetch = fetch,
): Promise<WaitlistResult> {
  if (!endpoint) return "unavailable";
  const parsed = waitlistSchema.safeParse(input);
  if (!parsed.success) return "invalid";
  try {
    const response = await post(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...parsed.data, website: input.website ?? "" }),
    });
    if (response.ok) return "ok";
    if (response.status === 400) return "invalid";
    return response.status === 429 ? "slow_down" : "error";
  } catch {
    return "error";
  }
}
