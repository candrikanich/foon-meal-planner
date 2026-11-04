// The confirmation email, through Resend's HTTP API. With no RESEND_API_KEY or WAITLIST_FROM nothing is sent.
export interface ResendConfig {
  apiKey: string;
  from: string;
}

export function resendConfigFromEnv(get: (key: string) => string | undefined): ResendConfig | null {
  const apiKey = get("RESEND_API_KEY");
  const from = get("WAITLIST_FROM");
  return apiKey && from ? { apiKey, from } : null;
}

const escapeHtml = (value: string) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export function confirmationEmail(message: { firstName: string | null; confirmUrl: string; unsubscribeUrl: string }) {
  const hello = message.firstName ? `Hi ${message.firstName},` : "Hi,";
  const text = [
    hello,
    "",
    "Thanks for joining the Foon founding-family waitlist. Please confirm your email so we know it's really you:",
    message.confirmUrl,
    "",
    "Foon helps one person share the weight of dinner with the whole family. Founding families use it free during the beta, then pay half price for the annual plan, for life.",
    "",
    "If you didn't ask for this, ignore this email and we'll delete your address within 30 days.",
    `Unsubscribe: ${message.unsubscribeUrl}`,
  ].join("\n");
  const html = `<p>${escapeHtml(hello)}</p>
<p>Thanks for joining the Foon founding-family waitlist. Please confirm your email so we know it's really you:</p>
<p><a href="${escapeHtml(message.confirmUrl)}">Confirm my email</a></p>
<p>Foon helps one person share the weight of dinner with the whole family. Founding families use it free during the beta, then pay half price for the annual plan, for life.</p>
<p style="color:#6b6058;font-size:13px">If you didn't ask for this, ignore this email and we'll delete your address within 30 days.
<a href="${escapeHtml(message.unsubscribeUrl)}">Unsubscribe</a></p>`;
  return { subject: "Confirm your spot on the Foon waitlist", text, html };
}

export async function sendViaResend(
  config: ResendConfig,
  to: string,
  message: { firstName: string | null; confirmUrl: string; unsubscribeUrl: string },
  post: typeof fetch = fetch,
): Promise<void> {
  const { subject, text, html } = confirmationEmail(message);
  const response = await post("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: config.from,
      to: [to],
      subject,
      text,
      html,
      headers: {
        "List-Unsubscribe": `<${message.unsubscribeUrl}>`,
        "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
      },
    }),
  });
  if (!response.ok) throw new Error(`Resend answered ${response.status}`);
}
