// Recipe link import (#21). No secrets: it fetches the page and reads its recipe data. The only database call is the
// per-user daily cap (#116), made with the caller's own token.
import { fetchPage } from "./fetch.ts";
import { handleImport } from "./handler.ts";

async function resolve(hostname: string, signal: AbortSignal): Promise<string[]> {
  const [v4, v6] = await Promise.all([
    Deno.resolveDns(hostname, "A", { signal }).catch(() => [] as string[]),
    Deno.resolveDns(hostname, "AAAA", { signal }).catch(() => [] as string[]),
  ]);
  return [...v4, ...v6];
}

// Env is read per call so a missing value fails the request, not the boot.
async function claimSlot(authorization: string): Promise<boolean> {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required");
  const response = await fetch(`${url}/rest/v1/rpc/claim_import_slot`, {
    method: "POST",
    headers: { apikey: anonKey, Authorization: authorization, "Content-Type": "application/json" },
    body: "{}",
  });
  if (!response.ok) throw new Error(`claim_import_slot status ${response.status}`);
  return (await response.json()) === true;
}

Deno.serve((req) =>
  handleImport(req, {
    claimSlot,
    fetchPage: (link) => fetchPage(link, { fetch, resolve }),
    log: (message, error) => console.error(message, error),
  })
);
