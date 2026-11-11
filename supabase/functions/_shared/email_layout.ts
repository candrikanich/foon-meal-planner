// The ends of Foon's emails, and the one-click unsubscribe pieces commercial email needs (CAN-SPAM).
import { type Email, escapeHtml, POSTAL_ADDRESS, SENDER } from "./resend.ts";
import { hex } from "./token.ts";

export const SUPPORT_EMAIL = "support@getfoon.com";

const footerStyle = "color:#6b6058;font-size:13px";

// Transactional email (about the account itself) needs no unsubscribe link: it names the sender, the postal address and
// where to write.
export function transactionalFooter(contact = SUPPORT_EMAIL) {
  const lines = [SENDER, ...POSTAL_ADDRESS, contact];
  return {
    text: ["--", ...lines].join("\n"),
    html: `<p style="${footerStyle}">${lines.map(escapeHtml).join("<br>")}</p>`,
  };
}

// A paragraph, or a bulleted list.
export type Block = string | { list: string[] };

// A transactional email from plain blocks, written out as both the text and the HTML part (every value escaped), with
// the transactional footer.
export function transactionalEmail(subject: string, blocks: Block[]): Omit<Email, "to"> {
  const footer = transactionalFooter();
  const text = [
    ...blocks.flatMap((block) =>
      typeof block === "string" ? [block, ""] : [...block.list.map((item) => `- ${item}`), ""]
    ),
    footer.text,
  ].join("\n");
  const html = [
    ...blocks.map((block) =>
      typeof block === "string"
        ? `<p>${escapeHtml(block)}</p>`
        : `<ul>${block.list.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`
    ),
    footer.html,
  ].join("\n");
  return { subject, text, html };
}

// Commercial email ends with who sent it, a valid postal address, and a working unsubscribe link. `effect` says what
// unsubscribing does, as "deletes your address right away".
export function commercialFooter(unsubscribeUrl: string, effect: string) {
  const text = [
    "--",
    SENDER,
    ...POSTAL_ADDRESS,
    `Unsubscribe (${effect}): ${unsubscribeUrl}`,
  ].join("\n");
  const html = `<p style="${footerStyle}">${[SENDER, ...POSTAL_ADDRESS].map(escapeHtml).join("<br>")}<br>
<a href="${escapeHtml(unsubscribeUrl)}">Unsubscribe</a> (${escapeHtml(effect)}).</p>`;
  return { text, html };
}

// RFC 2369 and RFC 8058: mail apps show their own unsubscribe button, and one tap POSTs to the URL.
export function unsubscribeHeaders(unsubscribeUrl: string): Record<string, string> {
  return {
    "List-Unsubscribe": `<${unsubscribeUrl}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  };
}

// HMAC-SHA256 of an id, keyed by a secret the function already has and a purpose, so an unsubscribe link needs no
// stored token and one list's signature can't unsubscribe from another.
export function unsubscribeSigner(purpose: string, secret: string): (id: string) => Promise<string> {
  const key = crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`${purpose}:${secret}`),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return async (id) => hex(await crypto.subtle.sign("HMAC", await key, new TextEncoder().encode(id))).slice(0, 32);
}
