// waitlist: the founding-family waitlist behind getfoon.com (#34).
//   POST {email, firstName?, website?}  sign up; always the same answer, whether or not the email is already here
//   GET  ?confirm=<token>               double opt-in link from the email; redirects to the site's confirmed/expired page
//   GET  ?unsubscribe=<id>.<signature>  unsubscribe link; POST to the same URL is the mail client's one-click form
// Everything about storage and mail is behind WaitlistDeps so the rules here are testable without either.
import { z } from "zod";

export type JoinOutcome = "send" | "skip" | "rate_limited";
export type ConfirmOutcome = "confirmed" | "expired" | "invalid";

export interface WaitlistDeps {
  // Origins allowed to POST from a browser; requests with no Origin (a mail client following a link) pass.
  allowedOrigins: readonly string[];
  siteUrl: string;
  // The Edge Function's own public URL, which the emailed links point at.
  functionUrl: string;
  join(input: { email: string; firstName: string | null; tokenHash: string; ipHash: string }): Promise<JoinOutcome>;
  confirm(tokenHash: string): Promise<ConfirmOutcome>;
  unsubscribe(id: string): Promise<boolean>;
  idFor(email: string): Promise<string | null>;
  newToken(): string;
  sha256(value: string): Promise<string>;
  // A stable, unguessable signature for an id: the unsubscribe link's proof.
  sign(id: string): Promise<string>;
  // "off" when email isn't configured (nothing sent); a send that fails throws.
  sendConfirmation(message: { to: string; firstName: string | null; confirmUrl: string; unsubscribeUrl: string }): Promise<"sent" | "off">;
  // Ids and outcomes only: never an email address.
  log(message: string, error?: unknown): void;
}

const signupSchema = z.object({
  email: z.string().trim().max(254).pipe(z.email()),
  firstName: z.string().trim().max(60).optional(),
  website: z.string().optional(),
});

const tokenPattern = /^[A-Za-z0-9_-]{20,100}$/;

const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Vary": "Origin",
});

function json(status: number, body: Record<string, unknown>, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...(origin ? corsHeaders(origin) : {}) },
  });
}

const redirect = (url: string) => new Response(null, { status: 303, headers: { Location: url } });

// Behind Supabase's proxy the first x-forwarded-for entry is the caller.
function callerAddress(req: Request): string {
  return (req.headers.get("x-forwarded-for")?.split(",")[0] ?? req.headers.get("cf-connecting-ip") ?? "unknown").trim();
}

export function unsubscribeUrl(deps: Pick<WaitlistDeps, "functionUrl">, id: string, signature: string): string {
  return `${deps.functionUrl}?unsubscribe=${id}.${signature}`;
}

async function signUp(req: Request, deps: WaitlistDeps, origin: string | null): Promise<Response> {
  const body = await req.json().catch(() => null);
  const parsed = signupSchema.safeParse(body);
  if (!parsed.success) return json(400, { error: "bad_request" }, origin);
  const { email, firstName, website } = parsed.data;
  // The honeypot is hidden from people; only a bot fills it. It gets the same answer as everyone, and nothing is stored.
  if (website) return json(200, { ok: true }, origin);

  const token = deps.newToken();
  const outcome = await deps.join({
    email,
    firstName: firstName || null,
    tokenHash: await deps.sha256(token),
    // Keyed, so the hash can't be reversed by trying every address.
    ipHash: await deps.sign(`ip:${callerAddress(req)}`),
  });
  if (outcome === "rate_limited") return json(429, { error: "slow_down" }, origin);
  if (outcome === "send") {
    const id = await deps.idFor(email);
    if (!id) throw new Error("signup vanished");
    const result = await deps.sendConfirmation({
      to: email,
      firstName: firstName || null,
      confirmUrl: `${deps.functionUrl}?confirm=${token}`,
      unsubscribeUrl: unsubscribeUrl(deps, id, await deps.sign(id)),
    });
    if (result === "off") deps.log("waitlist: email is off (RESEND_API_KEY or WAITLIST_FROM unset); signup stored, nothing sent");
  }
  return json(200, { ok: true }, origin);
}

async function unsubscribeFrom(param: string, deps: WaitlistDeps): Promise<boolean> {
  const [id, signature] = param.split(".");
  if (!id || !signature || !/^[0-9a-f-]{36}$/i.test(id)) return false;
  if (signature !== await deps.sign(id)) return false;
  return deps.unsubscribe(id);
}

export async function handleWaitlist(req: Request, deps: WaitlistDeps): Promise<Response> {
  const url = new URL(req.url);
  const origin = req.headers.get("Origin");
  const site = (path: string) => `${deps.siteUrl}${path}`;

  try {
    if (req.method === "GET") {
      const confirm = url.searchParams.get("confirm");
      if (confirm !== null) {
        if (!tokenPattern.test(confirm)) return redirect(site("/waitlist/expired"));
        const outcome = await deps.confirm(await deps.sha256(confirm));
        return redirect(site(outcome === "confirmed" ? "/waitlist/confirmed" : "/waitlist/expired"));
      }
      const unsubscribe = url.searchParams.get("unsubscribe");
      if (unsubscribe !== null) {
        return redirect(site(await unsubscribeFrom(unsubscribe, deps) ? "/waitlist/unsubscribed" : "/waitlist/expired"));
      }
      return json(404, { error: "not_found" }, null);
    }

    if (origin && !deps.allowedOrigins.includes(origin)) return json(403, { error: "forbidden" }, null);
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: origin ? corsHeaders(origin) : {} });
    }
    if (req.method === "POST") {
      const unsubscribe = url.searchParams.get("unsubscribe");
      if (unsubscribe !== null) {
        const done = await unsubscribeFrom(unsubscribe, deps);
        return json(done ? 200 : 400, done ? { ok: true } : { error: "bad_request" }, origin);
      }
      return await signUp(req, deps, origin);
    }
    return json(405, { error: "method_not_allowed" }, origin);
  } catch (error) {
    deps.log("waitlist: failed", error);
    return json(500, { error: "try_again" }, origin);
  }
}
