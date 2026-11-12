import { describe, expect, it } from "vitest";
import { confirmReceiptSender, receiptInboxEndpoint } from "../app/utils/receipts";

const reply = (status: number, body: unknown = {}) =>
  (() => Promise.resolve(new Response(JSON.stringify(body), { status }))) as unknown as typeof fetch;

const token = "Abc_DEF-0123456789abcdefghijkl";

describe("receiptInboxEndpoint", () => {
  it("uses its own setting when there is one", () => {
    expect(receiptInboxEndpoint("https://ref.supabase.co/functions/v1/receipt-inbox", "")).toBe(
      "https://ref.supabase.co/functions/v1/receipt-inbox",
    );
  });

  it("otherwise is the function next to the waitlist one", () => {
    expect(receiptInboxEndpoint("", "https://ref.supabase.co/functions/v1/waitlist")).toBe(
      "https://ref.supabase.co/functions/v1/receipt-inbox",
    );
  });

  it("is empty with neither (a preview build)", () => {
    expect(receiptInboxEndpoint("", "")).toBe("");
    expect(receiptInboxEndpoint("", "https://example.com/other")).toBe("");
  });
});

describe("confirmReceiptSender", () => {
  it("POSTs the token only when the button is pressed", async () => {
    let seen: { url: string; method?: string } | undefined;
    const spy = ((url: string, init: RequestInit) => {
      seen = { url, method: init.method };
      return Promise.resolve(new Response(JSON.stringify({ outcome: "confirmed" })));
    }) as unknown as typeof fetch;
    expect(await confirmReceiptSender("https://f/receipt-inbox", token, spy)).toBe("confirmed");
    expect(seen).toEqual({ url: `https://f/receipt-inbox?confirm=${encodeURIComponent(token)}`, method: "POST" });
  });

  it("maps the function's answers", async () => {
    expect(await confirmReceiptSender("https://f", token, reply(200, { outcome: "expired" }))).toBe("expired");
    expect(await confirmReceiptSender("https://f", token, reply(200, { outcome: "unknown" }))).toBe("unknown");
    expect(await confirmReceiptSender("https://f", token, reply(200, { outcome: "something new" }))).toBe("unknown");
    expect(await confirmReceiptSender("https://f", token, reply(400))).toBe("unknown");
    expect(await confirmReceiptSender("https://f", token, reply(500))).toBe("error");
    expect(await confirmReceiptSender("", token, reply(200))).toBe("error");
    const offline = (() => Promise.reject(new TypeError("offline"))) as unknown as typeof fetch;
    expect(await confirmReceiptSender("https://f", token, offline)).toBe("error");
  });
});
