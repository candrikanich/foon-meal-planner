// Recipe link import (#21). No secrets and no database access: it fetches the page and reads its recipe data.
import { fetchPage } from "./fetch.ts";
import { handleImport } from "./handler.ts";

async function resolve(hostname: string, signal: AbortSignal): Promise<string[]> {
  const [v4, v6] = await Promise.all([
    Deno.resolveDns(hostname, "A", { signal }).catch(() => [] as string[]),
    Deno.resolveDns(hostname, "AAAA", { signal }).catch(() => [] as string[]),
  ]);
  return [...v4, ...v6];
}

Deno.serve((req) =>
  handleImport(req, {
    fetchPage: (link) => fetchPage(link, { fetch, resolve }),
    log: (message, error) => console.error(message, error),
  })
);
