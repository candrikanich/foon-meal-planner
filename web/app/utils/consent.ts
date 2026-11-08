import { z } from "zod";

// The pages a parent lands on from the COPPA "email plus" emails (#275). Opening a link changes nothing: the page looks
// the token up, and only its buttons decide. The kid's first name comes from the lookup and never goes in a URL.

export const CONSENT_ROUTES = {
  done: "/consent/done",
  refused: "/consent/refused",
  expired: "/consent/expired",
  withdrawExpired: "/consent/expired?link=withdraw",
  withdrawn: "/consent/withdrawn",
} as const;

export type ConsentRoute = (typeof CONSENT_ROUTES)[keyof typeof CONSENT_ROUTES];

export type ConsentDecision = "lookup" | "agree" | "refuse";
export type WithdrawDecision = "lookup" | "withdraw";

export type ConsentStep =
  | { step: "ask"; firstName: string }
  // I agree was kept but email 2 didn't go out yet: tapping again resends.
  | { step: "again" }
  // No arrived while an I agree (another tab) is sending email 2: try again in a moment.
  | { step: "wait" }
  | { step: "go"; to: ConsentRoute }
  | { step: "error" };

export type WithdrawStep = { step: "ask"; firstName: string } | { step: "go"; to: ConsentRoute } | { step: "error" };

const consentReply = z.union([
  z.object({ result: z.literal("pending"), firstName: z.string().min(1) }),
  z.object({ result: z.enum(["try_again", "confirmed", "refused", "expired", "invalid"]) }),
]);

const withdrawReply = z.union([
  z.object({ result: z.literal("active"), firstName: z.string().min(1) }),
  z.object({ result: z.enum(["withdrawn", "expired", "invalid"]) }),
]);

export function consentStep(reply: z.infer<typeof consentReply>): ConsentStep {
  switch (reply.result) {
    case "pending":
      return { step: "ask", firstName: reply.firstName };
    case "try_again":
      return { step: "again" };
    case "confirmed":
      return { step: "go", to: CONSENT_ROUTES.done };
    case "refused":
      return { step: "go", to: CONSENT_ROUTES.refused };
    case "expired":
    case "invalid":
      return { step: "go", to: CONSENT_ROUTES.expired };
  }
}

export function withdrawStep(reply: z.infer<typeof withdrawReply>): WithdrawStep {
  switch (reply.result) {
    case "active":
      return { step: "ask", firstName: reply.firstName };
    case "withdrawn":
      return { step: "go", to: CONSENT_ROUTES.withdrawn };
    case "expired":
    case "invalid":
      return { step: "go", to: CONSENT_ROUTES.withdrawExpired };
  }
}

// null for anything that isn't a 200 with JSON: a network failure, 400 bad_request, 403 forbidden or 500 try_again.
async function postDecision(
  endpoint: string,
  link: "consent" | "withdraw",
  token: string,
  decision: string,
  post: typeof fetch,
): Promise<unknown> {
  try {
    const response = await post(`${endpoint}?${link}=${encodeURIComponent(token)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ decision }),
    });
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
}

export async function answerConsent(
  endpoint: string,
  token: string,
  decision: ConsentDecision,
  post: typeof fetch = fetch,
): Promise<ConsentStep> {
  // The server answers "invalid" to a missing token, so skip the call.
  if (!token) return { step: "go", to: CONSENT_ROUTES.expired };
  if (!endpoint) return { step: "error" };
  const parsed = consentReply.safeParse(await postDecision(endpoint, "consent", token, decision, post));
  if (!parsed.success) return { step: "error" };
  const step = consentStep(parsed.data);
  if (step.step !== "again" || decision === "agree") return step;
  // A refuse gets try_again only while an agree is mid-send; a lookup never should.
  return decision === "refuse" ? { step: "wait" } : { step: "error" };
}

export async function answerWithdraw(
  endpoint: string,
  token: string,
  decision: WithdrawDecision,
  post: typeof fetch = fetch,
): Promise<WithdrawStep> {
  if (!token) return { step: "go", to: CONSENT_ROUTES.withdrawExpired };
  if (!endpoint) return { step: "error" };
  const parsed = withdrawReply.safeParse(await postDecision(endpoint, "withdraw", token, decision, post));
  return parsed.success ? withdrawStep(parsed.data) : { step: "error" };
}

// What /consent and /consent/withdraw show. "problem" is a failed call: the page offers its buttons again.
export type PageState =
  | { view: "loading" }
  | { view: "unreachable" }
  | { view: "ask"; firstName: string; notice: "none" | "again" | "wait" | "problem" };

export type PageMove = { state: PageState } | { navigate: ConsentRoute };

// The next page state after a lookup (from "loading" or "unreachable") or a button (from "ask").
export function nextPage(current: PageState, step: ConsentStep | WithdrawStep): PageMove {
  if (step.step === "go") return { navigate: step.to };
  if (step.step === "ask") return { state: { view: "ask", firstName: step.firstName, notice: "none" } };
  if (current.view !== "ask") return { state: { view: "unreachable" } };
  return { state: { ...current, notice: step.step === "error" ? "problem" : step.step } };
}
