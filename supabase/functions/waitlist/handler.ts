// waitlist: the founding-family waitlist behind getfoon.com (#34).
//   POST {email, firstName?, website?}      sign up; always the same quick answer, whether or not the email is already here
//   POST ?confirm=<token>                   double opt-in, from the button on the site's /waitlist/confirm page
//   POST ?unsubscribe=<id>.<signature>      unsubscribe, from the site's page or a mail client's one-click (RFC 8058)
//   GET  ?confirm=… / ?unsubscribe=…        no side effects: only a redirect to those site pages, because link scanners
//                                           (Safe Links, Mimecast) open every link in an email before the person does
// Everything about storage and mail is behind WaitlistDeps so the rules here are testable without either.
import { z } from "zod";
import { clientKey, safeEqual } from "./client.ts";

export type JoinResult =
  | { outcome: "rate_limited" | "skip" }
  | { outcome: "send"; signupId: string; attemptId: number };
export type ConfirmOutcome = "confirmed" | "expired" | "invalid";

export interface WaitlistDeps {
  // Origins allowed to POST from a browser; requests with no Origin (a mail client's one-click) pass.
  allowedOrigins: readonly string[];
  siteUrl: string;
  // The Edge Function's own public URL, which the emailed links point at.
  functionUrl: string;
  join(
    input: { email: string; firstName: string | null; ipHash: string },
  ): Promise<JoinResult>;
  // join reserves the send under the database's lock. markSent confirms it once the email went out; releaseSend gives it
  // back when it didn't, so a retry sends and failures never fill the cap. A reservation nobody settles lapses on its own.
  releaseSend(input: { signupId: string; attemptId: number }): Promise<void>;
  markSent(
    input: {
      signupId: string;
      attemptId: number;
      tokenHash: string;
      firstName: string | null;
    },
  ): Promise<void>;
  confirm(tokenHash: string): Promise<ConfirmOutcome>;
  unsubscribe(id: string): Promise<void>;
  newToken(): string;
  sha256(value: string): Promise<string>;
  // A stable, unguessable signature for a value: the unsubscribe link's proof, and the keyed hash of an address.
  sign(value: string): Promise<string>;
  // "off" when email isn't configured (nothing sent); a send that fails throws.
  sendConfirmation(
    message: { to: string; confirmUrl: string; unsubscribeUrl: string },
  ): Promise<"sent" | "off">;
  // Runs work after the response has gone (EdgeRuntime.waitUntil), so a signup's answer never waits on, or reveals, a send.
  defer(work: Promise<unknown>): void;
  // Ids and outcomes only: never an email address.
  log(message: string, error?: unknown): void;
}

const signupSchema = z.object({
  email: z.string().trim().max(254).pipe(z.email()),
  // Letters, spaces, hyphens and apostrophes only: no digits, links or symbols, so a name is only ever a name.
  firstName: z.string().trim().max(40).regex(/^[\p{L}\p{M}][\p{L}\p{M} '’-]*$/u)
    .or(z.literal("")).optional(),
  website: z.string().optional(),
});

const tokenPattern = /^[A-Za-z0-9_-]{20,100}$/;
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Vary": "Origin",
});

function json(
  status: number,
  body: Record<string, unknown>,
  origin: string | null,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...(origin ? corsHeaders(origin) : {}),
    },
  });
}

const redirect = (url: string) =>
  new Response(null, { status: 303, headers: { Location: url } });

export function unsubscribeUrl(
  deps: Pick<WaitlistDeps, "functionUrl">,
  id: string,
  signature: string,
): string {
  return `${deps.functionUrl}?unsubscribe=${id}.${signature}`;
}

// Mails the link and, only if that worked, records it. If it didn't go out the reservation is released, so the person's
// next try sends again and the overall cap isn't filled by failures.
async function sendAndMark(
  deps: WaitlistDeps,
  send: {
    signupId: string;
    attemptId: number;
    email: string;
    firstName: string | null;
    token: string;
  },
): Promise<void> {
  const release = () =>
    deps.releaseSend({ signupId: send.signupId, attemptId: send.attemptId })
      .catch((error) => deps.log("waitlist: could not release a send", error));
  let result: "sent" | "off";
  try {
    result = await deps.sendConfirmation({
      to: send.email,
      confirmUrl: `${deps.functionUrl}?confirm=${send.token}`,
      unsubscribeUrl: unsubscribeUrl(
        deps,
        send.signupId,
        await deps.sign(send.signupId),
      ),
    });
  } catch (error) {
    deps.log("waitlist: confirmation not sent", error);
    return release();
  }
  if (result === "off") {
    deps.log(
      "waitlist: email is off (RESEND_API_KEY or WAITLIST_FROM unset); signup stored, nothing sent",
    );
    return release();
  }
  try {
    await deps.markSent({
      signupId: send.signupId,
      attemptId: send.attemptId,
      tokenHash: await deps.sha256(send.token),
      firstName: send.firstName,
    });
  } catch (error) {
    // The email is out but its token wasn't saved; the reservation lapses by itself and a retry sends a working one.
    deps.log("waitlist: sent but not recorded", error);
  }
}

async function signUp(
  req: Request,
  deps: WaitlistDeps,
  origin: string | null,
): Promise<Response> {
  const body = await req.json().catch(() => null);
  const parsed = signupSchema.safeParse(body);
  if (!parsed.success) return json(400, { error: "bad_request" }, origin);
  const { email, firstName, website } = parsed.data;
  // The honeypot is hidden from people; only a bot fills it. It gets the same answer as everyone, and nothing is stored.
  if (website) return json(200, { ok: true }, origin);

  const joined = await deps.join({
    email,
    firstName: firstName || null,
    // Keyed, so the hash can't be reversed by trying every address.
    ipHash: await deps.sign(`ip:${clientKey(req.headers)}`),
  });
  if (joined.outcome === "rate_limited") {
    return json(429, { error: "slow_down" }, origin);
  }
  if (joined.outcome === "send") {
    deps.defer(sendAndMark(deps, {
      signupId: joined.signupId,
      attemptId: joined.attemptId,
      email,
      firstName: firstName || null,
      token: deps.newToken(),
    }));
  }
  return json(200, { ok: true }, origin);
}

async function unsubscribeFrom(
  param: string,
  deps: WaitlistDeps,
): Promise<boolean> {
  const [id, signature] = param.split(".");
  if (!id || !signature || !uuidPattern.test(id)) return false;
  if (!safeEqual(signature, await deps.sign(id))) return false;
  // A second use of the link finds nothing left to delete, and that's still what they wanted.
  await deps.unsubscribe(id);
  return true;
}

export async function handleWaitlist(
  req: Request,
  deps: WaitlistDeps,
): Promise<Response> {
  const url = new URL(req.url);
  const origin = req.headers.get("Origin");
  const site = (path: string) => `${deps.siteUrl}${path}`;
  const confirm = url.searchParams.get("confirm");
  const unsubscribe = url.searchParams.get("unsubscribe");

  try {
    if (req.method === "GET") {
      if (confirm !== null) {
        return redirect(
          tokenPattern.test(confirm)
            ? site(`/waitlist/confirm?t=${confirm}`)
            : site("/waitlist/expired"),
        );
      }
      if (unsubscribe !== null) {
        return redirect(
          site(`/waitlist/unsubscribe?u=${encodeURIComponent(unsubscribe)}`),
        );
      }
      return json(404, { error: "not_found" }, null);
    }

    if (origin && !deps.allowedOrigins.includes(origin)) {
      return json(403, { error: "forbidden" }, null);
    }
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: origin ? corsHeaders(origin) : {},
      });
    }
    if (req.method !== "POST") {
      return json(405, { error: "method_not_allowed" }, origin);
    }

    if (confirm !== null) {
      if (!tokenPattern.test(confirm)) {
        return json(200, { result: "invalid" }, origin);
      }
      return json(200, {
        result: await deps.confirm(await deps.sha256(confirm)),
      }, origin);
    }
    if (unsubscribe !== null) {
      const done = await unsubscribeFrom(unsubscribe, deps);
      return json(
        done ? 200 : 400,
        done ? { ok: true } : { error: "bad_request" },
        origin,
      );
    }
    return await signUp(req, deps, origin);
  } catch (error) {
    deps.log("waitlist: failed", error);
    return json(500, { error: "try_again" }, origin);
  }
}
