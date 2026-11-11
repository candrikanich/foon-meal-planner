// Sending email through Resend's HTTP API. With no RESEND_API_KEY or sender address a function sends nothing.
export interface ResendConfig {
  apiKey: string;
  from: string;
}

export interface Email {
  to: string;
  subject: string;
  text: string;
  html: string;
  headers?: Record<string, string>;
  // Sent as Resend's Idempotency-Key request header (not an email header): a retry with the same key within 24 hours
  // isn't sent twice.
  idempotencyKey?: string;
}

// Each function has its own sender secret (WAITLIST_FROM, CONSENT_FROM); the API key is shared.
export function resendConfigFromEnv(
  get: (key: string) => string | undefined,
  fromKey: string,
): ResendConfig | null {
  const apiKey = get("RESEND_API_KEY");
  const from = get(fromKey);
  return apiKey && from ? { apiKey, from } : null;
}

export const escapeHtml = (value: string) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// Who sends Foon's email and its postal address: CAN-SPAM for the waitlist, and COPPA's notice names the operator.
export const SENDER = "Foon, from The Recruiting Compass LLC";
export const POSTAL_ADDRESS = [
  "34125 Center Ridge Road #1012",
  "North Ridgeville, OH 44039",
] as const;

// A hung call would hold a cron run (and its claimed renewals) past its budget; giving up is a failed send.
export const SEND_TIMEOUT_MS = 10_000;

// Throws when Resend doesn't accept the email or doesn't answer in time. The error names only the status, never the
// address.
export async function sendEmail(
  config: ResendConfig,
  email: Email,
  post: typeof fetch = fetch,
  timeoutMs = SEND_TIMEOUT_MS,
): Promise<void> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await post("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        "Content-Type": "application/json",
        ...(email.idempotencyKey ? { "Idempotency-Key": email.idempotencyKey } : {}),
      },
      body: JSON.stringify({
        from: config.from,
        to: [email.to],
        subject: email.subject,
        text: email.text,
        html: email.html,
        ...(email.headers ? { headers: email.headers } : {}),
      }),
      signal: controller.signal,
    });
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`Resend didn't answer in ${timeoutMs} ms`);
    throw error;
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) throw new Error(`Resend answered ${response.status}`);
}
