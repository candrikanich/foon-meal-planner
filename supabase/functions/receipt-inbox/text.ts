// A forwarded receipt's body as plain lines in receipt order, for the phone's ReceiptMatcher to read (it handles prices,
// totals and the rest). Pure, so the same mail always gives the same lines.

// What record_forwarded_receipt accepts.
export const MAX_LINES = 400;
export const MAX_LINE_LENGTH = 200;
// When the text part has fewer lines than this, it's a stub ("view this email in your browser") and the HTML is read.
const MIN_TEXT_LINES = 3;

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  middot: "·",
  bull: "•",
  ndash: "–",
  mdash: "—",
  hellip: "…",
  lsquo: "‘",
  rsquo: "’",
  ldquo: "“",
  rdquo: "”",
  times: "×",
  cent: "¢",
  pound: "£",
  euro: "€",
  copy: "©",
  reg: "®",
  trade: "™",
};

function codePoint(value: number): string {
  return Number.isInteger(value) && value > 0 && value <= 0x10ffff ? String.fromCodePoint(value) : "";
}

export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]{1,6}|#\d{1,7}|[a-z]+);/gi, (match, name: string) => {
    if (name[0] === "#") {
      return codePoint(name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10));
    }
    return NAMED_ENTITIES[name.toLowerCase()] ?? match;
  });
}

const BLOCK_OPEN = /<!--|<(script|style|head|title)\b/gi;

// Comments and script, style, head and title blocks, cut in one pass. A lazy regex rescans to the end of the mail for
// every opening without a close, which a stranger's mail can make quadratic; here an unclosed kind is noted once, its
// later openings are left as text, and the scan never goes back.
export function dropBlocks(html: string): string {
  const unclosed = new Set<string>();
  let out = "";
  let from = 0;
  BLOCK_OPEN.lastIndex = 0;
  for (let open = BLOCK_OPEN.exec(html); open; open = BLOCK_OPEN.exec(html)) {
    const kind = open[1]?.toLowerCase() ?? "comment";
    if (unclosed.has(kind)) continue;
    const after = open.index + open[0].length;
    let end = -1;
    if (kind === "comment") {
      const close = html.indexOf("-->", after);
      end = close === -1 ? -1 : close + 3;
    } else {
      const close = new RegExp(`</${kind}\\s*>`, "gi");
      close.lastIndex = after;
      const found = close.exec(html);
      end = found ? found.index + found[0].length : -1;
    }
    if (end === -1) {
      unclosed.add(kind);
      continue;
    }
    out += html.slice(from, open.index);
    from = end;
    BLOCK_OPEN.lastIndex = end;
  }
  return out + html.slice(from);
}

const LINE_TAGS = new Set(["br", "hr"]);
const LINE_CLOSES = new Set(["p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "ul", "ol"]);
const CELL_CLOSES = new Set(["td", "th"]);

// What a tag leaves behind: a line break, a cell gap, or nothing.
function tagBreak(inside: string): string {
  const closing = inside.startsWith("/");
  const name = (inside.slice(closing ? 1 : 0).match(/^[a-z0-9]+/i)?.[0] ?? "").toLowerCase();
  if (LINE_TAGS.has(name)) return "\n";
  if (closing && LINE_CLOSES.has(name)) return "\n";
  if (closing && CELL_CLOSES.has(name)) return " ";
  return "";
}

// Rows and blocks end lines; table cells stay on their row, so "Bananas | 2 | $1.29" reads as one line. One forward
// scan, never a regex that rescans: a "<" with no ">" after it ends the tags, and the rest stays text.
export function htmlToText(html: string): string {
  const source = dropBlocks(html);
  let text = "";
  let from = 0;
  while (from < source.length) {
    const open = source.indexOf("<", from);
    const close = open === -1 ? -1 : source.indexOf(">", open + 1);
    if (close === -1) {
      text += source.slice(from);
      break;
    }
    text += source.slice(from, open) + tagBreak(source.slice(open + 1, close));
    from = close + 1;
  }
  // Decoded last, so an escaped "&lt;b&gt;" in the receipt stays text instead of being read as a tag.
  return decodeEntities(text);
}

const FORWARD_MARKERS = [
  /^-{2,}\s*Forwarded message\s*-{2,}$/i,
  /^Begin forwarded message:?$/i,
  /^-{2,}\s*Original Message\s*-{2,}$/i,
];
const FORWARD_HEADER = /^(From|Date|Sent|Subject|To|Cc|Reply-To):/i;

// Mail apps quote with leading ">"; invisible format characters pad marketing mail's preheaders.
const clean = (line: string) =>
  line
    .replace(/^(\s*>)+/, "")
    .replace(/[\p{Cc}\p{Cf}]/gu, "")
    .replace(/\s+/g, " ")
    .trim();

// Code points rather than UTF-16 units, as Postgres's char_length counts, and so an emoji isn't cut in half.
const clip = (line: string) => {
  const points = Array.from(line);
  return points.length > MAX_LINE_LENGTH ? points.slice(0, MAX_LINE_LENGTH).join("") : line;
};

// Labels over a person's name or address. Inline ("Ship to: Sam, 12 Elm St") the line goes; alone ("Ship to") the
// block under it goes too, up to a blank line. A lone name label needs its colon: "MEMBER" or "Name" by itself is
// as likely a receipt's own heading over item lines.
const NAME_LABEL = "name|customer|member|cardholder|account holder";
const ADDRESS_LABEL = "bill to|billing address|ship to|shipping address|deliver to|delivered to|delivery address|address";
const PERSON_LABEL = `${NAME_LABEL}|${ADDRESS_LABEL}`;
const LABEL_ALONE = new RegExp(`^(?:(?:${ADDRESS_LABEL})\\s*:?|(?:${NAME_LABEL})\\s*:)$`, "i");
const LABEL_BLOCK_LINES = 4;

// Lines that name or reach a person: an email address, a phone number, a payment card, or a labelled name or address.
// The phone's ReceiptMatcher only wants items, so dropping one of these never costs a match (minimal data, CLAUDE.md
// rule 4). Best effort: a greeting such as "Sam, here's your receipt" still gets through.
const PERSONAL = [
  /[^\s@<>]+@[^\s@<>]+\.[a-z]{2,}/i,
  /(?:\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b/,
  /\b(?:visa|mastercard|master card|amex|american express|discover|debit|credit|card)\b.*\b\d{4}\b/i,
  /\b(?:ending|ends) in\b/i,
  /[*•x]{2,}\s?\d{4}\b/i,
  new RegExp(`^(?:${PERSON_LABEL})\\s*:`, "i"),
];
const LINK = /<?\bhttps?:\/\/[^\s>]*>?/gi;
// Outlook's forward: a rule of underscores, then From/Sent/To/Subject. Only a marker when a From line follows, so a
// receipt's own underscore divider stays.
const OUTLOOK_RULE = /^_{10,}$/;

// Links carry tracking tokens and order ids; the words around them stay.
const withoutLinks = (line: string) => line.replace(LINK, " ").replace(/\s+/g, " ").trim();

// For each line, the next non-empty line after it, found in one backward pass so the Outlook check stays linear.
function nextNonEmpty(lines: string[]): (string | undefined)[] {
  const next: (string | undefined)[] = new Array(lines.length);
  let found: string | undefined;
  for (let index = lines.length - 1; index >= 0; index--) {
    next[index] = found;
    if (lines[index] !== "") found = lines[index];
  }
  return next;
}

function isForwardMarker(line: string, nextLine: string | undefined): boolean {
  if (FORWARD_MARKERS.some((marker) => marker.test(line))) return true;
  return OUTLOOK_RULE.test(line) && nextLine !== undefined && /^From:/i.test(nextLine);
}

// Only the header block straight after a forwarding marker is dropped: a "To:" line elsewhere may be the receipt's.
// What came before the first marker is the forwarder's own note and signature, not the receipt, so it goes too; a
// later marker starts another forwarded receipt in the same email, and what came before it stays.
export function textToLines(text: string): string[] {
  // Clipped before the patterns run, so a stranger's one huge line can't make them slow; it's what's stored anyway.
  const source = text.split(/\r\n|\r|\n/).map((raw) => clip(withoutLinks(clean(raw))));
  const following = nextNonEmpty(source);
  let lines: string[] = [];
  let seenMarker = false;
  let inForwardHeader = false;
  let labelBlockLeft = 0;
  for (let index = 0; index < source.length; index++) {
    const line = source[index];
    if (isForwardMarker(line, following[index])) {
      if (!seenMarker) lines = [];
      seenMarker = true;
      inForwardHeader = true;
      labelBlockLeft = 0;
      continue;
    }
    if (inForwardHeader) {
      if (line === "" || FORWARD_HEADER.test(line)) continue;
      inForwardHeader = false;
    }
    if (line === "") {
      labelBlockLeft = 0;
      continue;
    }
    if (labelBlockLeft > 0) {
      labelBlockLeft--;
      continue;
    }
    if (LABEL_ALONE.test(line)) {
      labelBlockLeft = LABEL_BLOCK_LINES;
      continue;
    }
    if (PERSONAL.some((pattern) => pattern.test(line))) continue;
    lines.push(line);
    if (lines.length === MAX_LINES) break;
  }
  return lines;
}

export function receiptLines(text: string | null | undefined, html: string | null | undefined): string[] {
  const fromText = textToLines(text ?? "");
  if (fromText.length >= MIN_TEXT_LINES || !html) return fromText;
  const fromHtml = textToLines(htmlToText(html));
  return fromHtml.length > 0 ? fromHtml : fromText;
}
