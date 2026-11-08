// The confirmation email, through Resend (_shared/resend.ts). With no RESEND_API_KEY or WAITLIST_FROM nothing is sent.
import {
  escapeHtml,
  POSTAL_ADDRESS,
  type ResendConfig,
  sendEmail,
  SENDER,
} from "../_shared/resend.ts";

// CAN-SPAM: the confirmation carries the founding-family offer, so it's commercial. Every waitlist email ends with this
// footer: who sent it, a valid postal address, and a working unsubscribe link.
export function emailFooter(unsubscribeUrl: string) {
  const text = [
    "--",
    SENDER,
    ...POSTAL_ADDRESS,
    `Unsubscribe (deletes your address right away): ${unsubscribeUrl}`,
  ].join("\n");
  const html = `<p style="color:#6b6058;font-size:13px">${
    [SENDER, ...POSTAL_ADDRESS].map(escapeHtml).join("<br>")
  }<br>
<a href="${
    escapeHtml(unsubscribeUrl)
  }">Unsubscribe</a> (deletes your address right away).</p>`;
  return { text, html };
}

// Nothing the signer typed goes into the email: it comes from our domain before anyone has confirmed it's theirs, so a
// typed name could carry someone else's words.
export function confirmationEmail(
  message: { confirmUrl: string; unsubscribeUrl: string },
) {
  const hello = "Hi,";
  const footer = emailFooter(message.unsubscribeUrl);
  const text = [
    hello,
    "",
    "Thanks for joining the Foon founding-family waitlist. Please confirm your email so we know it's really you:",
    message.confirmUrl,
    "",
    "Foon helps one person share the weight of dinner with the whole family. Founding families use it free during the beta, then pay half price for the annual plan, for life.",
    "",
    "If you didn't ask for this, ignore this email: we delete an address that isn't confirmed 30 days after this email goes out.",
    "",
    footer.text,
  ].join("\n");
  const html = `<p>${escapeHtml(hello)}</p>
<p>Thanks for joining the Foon founding-family waitlist. Please confirm your email so we know it's really you:</p>
<p><a href="${escapeHtml(message.confirmUrl)}">Confirm my email</a></p>
<p>Foon helps one person share the weight of dinner with the whole family. Founding families use it free during the beta, then pay half price for the annual plan, for life.</p>
<p style="color:#6b6058;font-size:13px">If you didn't ask for this, ignore this email: we delete an address that isn't confirmed 30 days after this email goes out.</p>
${footer.html}`;
  return { subject: "Confirm your spot on the Foon waitlist", text, html };
}

export async function sendViaResend(
  config: ResendConfig,
  to: string,
  message: { confirmUrl: string; unsubscribeUrl: string },
  post: typeof fetch = fetch,
): Promise<void> {
  await sendEmail(config, {
    to,
    ...confirmationEmail(message),
    headers: {
      "List-Unsubscribe": `<${message.unsubscribeUrl}>`,
      "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
    },
  }, post);
}
