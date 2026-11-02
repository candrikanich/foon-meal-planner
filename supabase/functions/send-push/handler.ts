// send-push: pg_cron pokes it every minute something's due, with a shared secret. It claims due outbox rows, sends each to
// its person's devices, forgets the tokens Apple says are dead, and marks each row sent (and logged), to retry, or failed.

import { alertFor, type ApnsPayload, type DeliveryResult, type Device, payloadFor } from "./apns.ts";

export interface OutboxRow {
  id: string;
  kind: string;
  // The plan's week, for the tap's route; null when the row isn't about a plan.
  week_start: string | null;
  attempts: number;
  devices: Device[];
}

export type Outcome = "sent" | "retry" | "no_devices" | "unknown_kind";

export interface SendPushDeps {
  cronSecret: string | undefined;
  // Null when the Apple secrets aren't set, so nothing is claimed and burned.
  providerToken: (() => Promise<string>) | null;
  claim(limit: number): Promise<OutboxRow[]>;
  deliver(device: Device, payload: ApnsPayload, jwt: string): Promise<DeliveryResult>;
  forgetDevices(tokens: string[]): Promise<void>;
  complete(id: string, outcome: Outcome): Promise<void>;
  log(message: string, error?: unknown): void;
}

const batchSize = 100;
// Well inside a minute, so one run is done before the next is poked.
const maxBatches = 5;

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function sameSecret(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let difference = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) difference |= (a[i] ?? 0) ^ b[i];
  return difference === 0;
}

export async function handleSendPush(req: Request, deps: SendPushDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const given = req.headers.get("x-push-secret");
  if (!deps.cronSecret || !given || !sameSecret(given, deps.cronSecret)) return json(401, { error: "unauthorized" });
  if (!deps.providerToken) {
    deps.log("apple secrets are not set");
    return json(500, { error: "not_configured" });
  }

  const totals: Record<Outcome, number> = { sent: 0, retry: 0, no_devices: 0, unknown_kind: 0 };
  try {
    const jwt = await deps.providerToken();
    for (let batch = 0; batch < maxBatches; batch++) {
      const rows = await deps.claim(batchSize);
      for (const row of rows) {
        const outcome = await send(row, jwt, deps);
        await deps.complete(row.id, outcome);
        totals[outcome] += 1;
      }
      if (rows.length < batchSize) break;
    }
  } catch (error) {
    // What's claimed and not completed goes back out when its hold ends.
    deps.log("send-push failed", error);
    return json(500, { error: "send_failed", ...totals });
  }
  return json(200, totals);
}

async function send(row: OutboxRow, jwt: string, deps: SendPushDeps): Promise<Outcome> {
  const alert = alertFor(row.kind);
  if (!alert) return "unknown_kind";
  if (row.devices.length === 0) return "no_devices";

  const payload = payloadFor(alert, row.week_start);
  const results = await Promise.all(row.devices.map((device) => deps.deliver(device, payload, jwt)));
  const dead = row.devices.filter((_, i) => results[i] === "dead_token").map((device) => device.token);
  if (dead.length > 0) await deps.forgetDevices(dead);

  if (results.includes("delivered")) return "sent";
  return dead.length === row.devices.length ? "no_devices" : "retry";
}
