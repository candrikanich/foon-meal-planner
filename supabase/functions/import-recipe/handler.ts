// import-recipe: POST { url } → { recipe, title, caption, url }. `recipe` is null when the page has no recipe data; the app
// then saves just the title and link. The gateway verifies the token's signature (verify_jwt), but the app's anon
// key is a valid token too, so the handler also requires a signed-in user.
import { BlockedURL } from "./fetch.ts";
import { parsePage } from "./recipe.ts";

export interface ImportDeps {
  fetchPage(link: string): Promise<{ html: string; url: string }>;
  log(message: string, error?: unknown): void;
}

// The gateway already checked the signature; this reads who it's for. Anon (the key shipped in the app) isn't enough.
export function isSignedInUser(authorization: string | null): boolean {
  const payload = authorization?.match(/^Bearer [^.]+\.([^.]+)\./)?.[1];
  if (!payload) return false;
  try {
    const claims = JSON.parse(atob(payload.replaceAll("-", "+").replaceAll("_", "/"))) as {
      role?: unknown;
      sub?: unknown;
    };
    return claims.role === "authenticated" && typeof claims.sub === "string" && claims.sub.length > 0;
  } catch {
    return false;
  }
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handleImport(req: Request, deps: ImportDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!isSignedInUser(req.headers.get("Authorization"))) return json(401, { error: "not_signed_in" });

  const body = await req.json().catch(() => null) as { url?: unknown } | null;
  const link = body?.url;
  if (typeof link !== "string" || link.length === 0 || link.length > 2048) {
    return json(400, { error: "url_required" });
  }

  try {
    const page = await deps.fetchPage(link.trim());
    const parsed = parsePage(page.html);
    return json(200, { recipe: parsed.recipe, title: parsed.title, caption: parsed.caption, url: page.url });
  } catch (error) {
    if (error instanceof BlockedURL) return json(400, { error: "url_not_allowed" });
    // The kind of failure only: messages can carry page-controlled text (a redirect's Location).
    deps.log("recipe page unavailable", error instanceof Error ? error.constructor.name : typeof error);
    return json(502, { error: "page_unavailable" });
  }
}
