import { assert, assertEquals } from "@std/assert";
import { decodeEntities, dropBlocks, htmlToText, MAX_LINE_LENGTH, MAX_LINES, receiptLines, textToLines } from "./text.ts";

const GROCERY_HTML = `<!DOCTYPE html>
<html><head><title>Your receipt</title><style>td { padding: 4px }</style></head>
<body>
<!-- tracking pixel below -->
<div style="display:none">&#8204;&nbsp;&#8204;&nbsp;</div>
<div class="gmail_quote"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>
From: <strong>Green Grocer</strong> <span>&lt;receipts@greengrocer.example&gt;</span><br>
Date: Mon, Nov 10, 2026 at 5:12&#8239;PM<br>
Subject: Your Green Grocer receipt<br>
To: &lt;chris@example.com&gt;<br></div><br><br>
<h1>Thanks for shopping, Chris!</h1>
<p>Store #42 &middot; 100 Main St</p>
<table>
  <tr><th>Item</th><th>Qty</th><th>Price</th></tr>
  <tr><td>Bananas</td><td>2</td><td>$1.29</td></tr>
  <tr><td>Ben &amp; Jerry&#39;s Cherry Garcia</td><td>1</td><td>$5.49</td></tr>
  <tr><td>BNLS CHKN BRST</td><td>1</td><td>&#x24;9.87</td></tr>
  <tr><td>Whole&nbsp;Milk   1 gal</td><td>1</td><td>$3.99</td></tr>
</table>
<p>Subtotal $20.64<br>Tax $0.00<br>Total $20.64</p>
<script>track()</script>
</div></body></html>`;

Deno.test("a grocery receipt's HTML reads as its rows, in order", () => {
  assertEquals(receiptLines("", GROCERY_HTML), [
    "Thanks for shopping, Chris!",
    "Store #42 · 100 Main St",
    "Item Qty Price",
    "Bananas 2 $1.29",
    "Ben & Jerry's Cherry Garcia 1 $5.49",
    "BNLS CHKN BRST 1 $9.87",
    "Whole Milk 1 gal 1 $3.99",
    "Subtotal $20.64",
    "Tax $0.00",
    "Total $20.64",
  ]);
});

const GMAIL_TEXT = [
  "Here's the one from Saturday",
  "",
  "---------- Forwarded message ---------",
  "From: Green Grocer <receipts@greengrocer.example>",
  "Date: Sat, Nov 8, 2026 at 10:02 AM",
  "Subject: Your Green Grocer receipt",
  "To: <chris@example.com>",
  "",
  "",
  "GREEN GROCER #42",
  "> BANANAS            1.29",
  ">   MILK 2%  1GAL      3.99",
  "",
  "TOTAL              5.28",
  "To: be paid on card ending 1234",
].join("\r\n");

Deno.test("a forward from Gmail keeps the receipt and drops the forwarding header block", () => {
  assertEquals(receiptLines(GMAIL_TEXT, "<p>ignored</p>"), [
    "GREEN GROCER #42",
    "BANANAS 1.29",
    "MILK 2% 1GAL 3.99",
    "TOTAL 5.28",
  ]);
});

Deno.test("the forwarder's note and signature above the forwarded message are dropped", () => {
  const text = [
    "Thanks,",
    "Sam Doe | example.org",
    "twitter.com/samdoe",
    "",
    "> Begin forwarded message:",
    "> From: Store <no-reply@store.example>",
    "> Subject: Your receipt",
    ">",
    "> 1 x Raspberries, 12 oz",
    "> $6.34",
  ].join("\n");
  assertEquals(textToLines(text), ["1 x Raspberries, 12 oz", "$6.34"]);
});

Deno.test("lines with an address, a phone number, a card or a name label are dropped, and links are cut", () => {
  const text = [
    "Contact: sam@example.org",
    "Call 216-555-0123 or (216) 555 0123 or +1 216.555.0123",
    "Your Visa 4822 card was temporarily authorized for $271.00.",
    "Paid with card ending in 1234",
    "Mastercard **** 9876",
    "Name: SAM DOE",
    "Customer: Sam",
    "Report an issue <https://store.example/help/123?token=abc>",
    "View Order <https://store.example/orders/1?euid=MTM4>Rate http://store.example/rate/9",
    "1 x Kirkland Signature Rotisserie Chicken",
    "Item 1919858",
    "UPC 012345678905",
    "$5.66",
    "Total: $271.00",
  ].join("\n");
  assertEquals(textToLines(text), [
    "Report an issue",
    "View Order Rate",
    "1 x Kirkland Signature Rotisserie Chicken",
    "Item 1919858",
    "UPC 012345678905",
    "$5.66",
    "Total: $271.00",
  ]);
});

Deno.test("Apple Mail's and Outlook's markers count too", () => {
  assertEquals(textToLines("Begin forwarded message:\n\nFrom: A <a@b.c>\nSubject: x\nEGGS 2.99"), ["EGGS 2.99"]);
  assertEquals(textToLines("-----Original Message-----\nSent: today\nTo: me\nEGGS 2.99"), ["EGGS 2.99"]);
});

Deno.test("a text part that's only a stub falls back to the HTML", () => {
  assertEquals(receiptLines("View this email in your browser", "<p>EGGS 2.99</p><p>MILK 3.99</p>"), [
    "EGGS 2.99",
    "MILK 3.99",
  ]);
  assertEquals(receiptLines("View this email in your browser", null), ["View this email in your browser"]);
  assertEquals(receiptLines("only", "<div></div>"), ["only"]);
  assertEquals(receiptLines(null, null), []);
});

Deno.test("lines are clipped to 200 code points and there are at most 400", () => {
  const long = "🍌".repeat(MAX_LINE_LENGTH + 5);
  const [clipped] = textToLines(long);
  assertEquals(Array.from(clipped).length, MAX_LINE_LENGTH);
  assert(Array.from(clipped).every((c) => c === "🍌"), "no emoji cut in half");
  const many = Array.from({ length: 450 }, (_, i) => `ITEM ${i}`).join("\n");
  assertEquals(textToLines(many).length, MAX_LINES);
});

Deno.test("several receipts forwarded in one email are all kept", () => {
  const text = [
    "Begin forwarded message:",
    "From: A <a@a.example>",
    "",
    "RECEIPT ONE",
    "APPLES 1.00",
    "",
    "Begin forwarded message:",
    "From: B <b@b.example>",
    "",
    "RECEIPT TWO",
    "PEARS 2.00",
  ].join("\n");
  assertEquals(textToLines(text), ["RECEIPT ONE", "APPLES 1.00", "RECEIPT TWO", "PEARS 2.00"]);
});

Deno.test("Outlook's underscore divider before a From header counts as a forward; a plain divider doesn't", () => {
  const outlook = [
    "See attached",
    "Sam Doe",
    "Senior Engineer, Acme",
    "",
    "________________________________",
    "From: Store <no-reply@store.example>",
    "Sent: Monday, October 26, 2026 5:05 PM",
    "To: sam@x.example",
    "Subject: Your receipt",
    "",
    "BANANAS 1.29",
  ].join("\n");
  assertEquals(textToLines(outlook), ["BANANAS 1.29"]);
  assertEquals(textToLines("GREEN GROCER\n______________________\nBANANAS 1.29"), [
    "GREEN GROCER",
    "______________________",
    "BANANAS 1.29",
  ]);
});

Deno.test("a name or address block under a label is dropped, with or without a colon", () => {
  const text = [
    "Ship to",
    "Sam Doe",
    "123 Elm St",
    "Cleveland, OH 44101",
    "",
    "1 x Raspberries, 12 oz",
    "Delivery address:",
    "Sam Doe",
    "",
    "$6.34",
    "Ship to: Sam Doe, 123 Elm St",
  ].join("\n");
  assertEquals(textToLines(text), ["1 x Raspberries, 12 oz", "$6.34"]);
});

Deno.test("the checks stay fast on one huge line and on many divider lines", () => {
  const started = performance.now();
  textToLines("card ".repeat(200_000) + "x".repeat(500_000));
  textToLines("____________\n".repeat(150_000));
  assert(performance.now() - started < 1000);
});

Deno.test("entities decode once, and escaped tags stay text", () => {
  assertEquals(decodeEntities("&amp;lt; &#65;&#x42; &QUOT; &bogus; &#0;"), '&lt; AB " &bogus; ');
  assertEquals(htmlToText("<td>&lt;b&gt;2 for 1&lt;/b&gt;</td>").trim(), "<b>2 for 1</b>");
});

Deno.test("an unclosed style or comment doesn't hide the receipt and stays linear", () => {
  const html = "<style>p{}<p>Bananas 0.59</p><p>Milk 3.49</p><!-- x <p>Eggs 2.99</p>";
  assertEquals(receiptLines(null, html).length > 0, true);
  const hostile = "<style>".repeat(50_000) + "<!--".repeat(50_000);
  const started = performance.now();
  dropBlocks(hostile);
  assertEquals(performance.now() - started < 1_000, true);
});

Deno.test("closed blocks and comments are cut, in any case", () => {
  assertEquals(dropBlocks("a<!-- x -->b<STYLE type=x>c</style >d<script>e</SCRIPT>f"), "abdf");
});

Deno.test("tags are stripped in linear time, and a stray < keeps the rest as text", () => {
  const started = performance.now();
  htmlToText("<".repeat(400_000) + "<hr".repeat(30_000));
  assertEquals(performance.now() - started < 1_000, true);
  assertEquals(htmlToText("<p>Milk</p><br class=x>Eggs < 3"), "Milk\n\nEggs < 3");
});
