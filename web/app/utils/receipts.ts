// Confirming an address that forwards receipts to a family's Foon (#237): the emailed link opens /receipts/confirm.

export type ReceiptConfirmResult = "confirmed" | "expired" | "unknown" | "error";

// NUXT_PUBLIC_RECEIPT_INBOX_URL when it's set; otherwise the receipt-inbox function next to the waitlist one, so a build
// without the new setting still works. Empty when there's neither (a preview build), like the forms.
export function receiptInboxEndpoint(receiptInboxUrl: string, waitlistUrl: string): string {
  if (receiptInboxUrl) return receiptInboxUrl;
  const match = waitlistUrl.match(/^(.*\/functions\/v1\/)waitlist\/?$/);
  return match ? `${match[1]}receipt-inbox` : "";
}

// Runs only when the person presses the page's button: mail scanners open every link in a message.
export async function confirmReceiptSender(
  endpoint: string,
  token: string,
  post: typeof fetch = fetch,
): Promise<ReceiptConfirmResult> {
  if (!endpoint) return "error";
  try {
    const response = await post(`${endpoint}?confirm=${encodeURIComponent(token)}`, { method: "POST" });
    if (response.status === 400) return "unknown";
    if (!response.ok) return "error";
    const body = await response.json();
    return body?.outcome === "confirmed" || body?.outcome === "expired" ? body.outcome : "unknown";
  } catch {
    return "error";
  }
}
