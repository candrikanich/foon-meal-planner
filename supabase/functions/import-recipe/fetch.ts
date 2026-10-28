// Fetches a recipe page on someone's behalf without becoming a way into private networks: http(s) on the usual
// ports only, names only (no IPv6 literals), no addresses on loopback, private, or link-local ranges (checked on the
// resolved addresses and again on every redirect), a time limit covering DNS and the body, and a size cap.

export class BlockedURL extends Error {}
export class PageUnavailable extends Error {}

export interface FetchDeps {
  fetch: typeof fetch;
  // IPv4 and IPv6 addresses for a host name. The fetch resolves the name again, so a DNS server that answers
  // differently the second time (rebinding) isn't caught here; the platform's egress rules are the backstop.
  resolve(hostname: string, signal: AbortSignal): Promise<string[]>;
}

const maxBytes = 2_000_000;
const maxRedirects = 3;
const timeoutMs = 10_000;

function isPrivateIPv4(a: number, b: number): boolean {
  return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 198 && (b === 18 || b === 19)) || a >= 224;
}

// The eight 16-bit groups of an IPv6 address, or null if it isn't one. Handles "::" and a dotted IPv4 tail.
function ipv6Groups(address: string): number[] | null {
  let text = address;
  const tail = text.match(/(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (tail) {
    const [a, b, c, d] = tail.slice(1).map(Number);
    text = text.slice(0, tail.index) + `${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const parse = (part: string) => (part ? part.split(":").map((group) => parseInt(group, 16)) : []);
  const head = parse(halves[0]);
  const rest = halves.length === 2 ? parse(halves[1]) : [];
  const groups = halves.length === 2 ? [...head, ...Array(8 - head.length - rest.length).fill(0), ...rest] : head;
  return groups.length === 8 && groups.every((group) => Number.isInteger(group) && group >= 0 && group <= 0xffff)
    ? groups
    : null;
}

export function isPrivateAddress(address: string): boolean {
  const ip = address.toLowerCase().replace(/^\[|\]$/g, "");
  const v4 = ip.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (v4) return isPrivateIPv4(Number(v4[1]), Number(v4[2]));
  const groups = ipv6Groups(ip);
  // Anything we can't read as an address is treated as private: refuse rather than guess.
  if (!groups) return true;
  const [g0, g1, g2, g3, g4, g5, g6] = groups;
  const embeddedV4 = () => isPrivateIPv4(g6 >> 8, g6 & 0xff);
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0) {
    if (g5 === 0) return true; // ::, ::1, and the old IPv4-compatible form
    if (g5 === 0xffff) return embeddedV4(); // IPv4-mapped: as private as the IPv4 address inside
  }
  if (g0 === 0x64 && g1 === 0xff9b) return true; // NAT64 can reach any IPv4, private ones included
  if (g0 === 0x2002) return true; // 6to4 wraps an IPv4 address
  return (g0 & 0xfe00) === 0xfc00 || (g0 & 0xffc0) === 0xfe80 || (g0 & 0xffc0) === 0xfec0 || (g0 & 0xff00) === 0xff00;
}

async function checkURL(url: URL, deps: FetchDeps, signal: AbortSignal): Promise<void> {
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new BlockedURL("only web links");
  if (url.username || url.password) throw new BlockedURL("no credentials in links");
  if (url.port && url.port !== "80" && url.port !== "443") throw new BlockedURL("unusual port");
  const host = url.hostname.toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) {
    throw new BlockedURL("local host");
  }
  // Recipe sites use names. IPv6 literals have too many ways to spell an internal address, so they're refused.
  if (host.startsWith("[") || host.includes(":")) throw new BlockedURL("address literal");
  const literal = /^[\d.]+$/.test(host);
  const addresses = literal ? [host] : await deps.resolve(host, signal).catch(() => []);
  if (addresses.length === 0) throw new PageUnavailable("host not found");
  if (addresses.some(isPrivateAddress)) throw new BlockedURL("private address");
}

async function readCapped(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (total < maxBytes) {
    const { done, value } = await reader.read();
    if (done) break;
    // Keep what fits of the chunk that crosses the cap; the rest of the page isn't needed.
    const kept = value.subarray(0, maxBytes - total);
    chunks.push(kept);
    total += kept.length;
  }
  if (total >= maxBytes) await reader.cancel();
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(bytes);
}

export async function fetchPage(link: string, deps: FetchDeps): Promise<{ html: string; url: string }> {
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    throw new BlockedURL("not a link");
  }
  const signal = AbortSignal.timeout(timeoutMs);
  for (let hop = 0; hop <= maxRedirects; hop++) {
    await checkURL(url, deps, signal);
    let response: Response;
    try {
      response = await deps.fetch(url, {
        redirect: "manual",
        signal,
        headers: { "User-Agent": "FoonRecipeImport/1.0 (+https://foon.app)", Accept: "text/html" },
      });
    } catch {
      throw new PageUnavailable("fetch failed");
    }
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("Location");
      await response.body?.cancel();
      if (!location) throw new PageUnavailable("redirect without location");
      try {
        url = new URL(location, url);
      } catch {
        throw new PageUnavailable("bad redirect");
      }
      continue;
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new PageUnavailable(`status ${response.status}`);
    }
    const type = response.headers.get("Content-Type") ?? "";
    if (!/text\/html|application\/xhtml\+xml/i.test(type)) {
      await response.body?.cancel();
      throw new PageUnavailable("not a web page");
    }
    return { html: await readCapped(response), url: url.toString() };
  }
  throw new PageUnavailable("too many redirects");
}
