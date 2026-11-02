// APNs: the provider token, the fixed words for each kind of push, and one POST per device. The same Apple key as Sign in
// with Apple ("Foon 2026" has APNs on, Sandbox and Production), so no new secrets.

import { signES256 } from "../_shared/es256.ts";

export interface ApnsConfig {
  teamId: string;
  keyId: string;
  // The .p8 key's contents (PKCS #8 PEM).
  privateKey: string;
}

export type Environment = "sandbox" | "production";

export interface Device {
  token: string;
  environment: Environment;
}

export interface Alert {
  title: string;
  body: string;
}

export interface ApnsPayload {
  aps: { alert: Alert; sound: "default" };
  // The routes local reminders use (ReminderPayload in ReminderCenter.swift), so a tap opens the same place.
  route?: "week";
  date?: string;
}

export type DeliveryResult = "delivered" | "dead_token" | "retry";

export const topic = "com.andrikanich.foon";

export function apnsConfigFromEnv(get: (key: string) => string | undefined): ApnsConfig | null {
  const teamId = get("APPLE_TEAM_ID");
  const keyId = get("APPLE_KEY_ID");
  const privateKey = get("APPLE_PRIVATE_KEY");
  if (!teamId || !keyId || !privateKey) return null;
  return { teamId, keyId, privateKey };
}

export function apnsHost(environment: Environment): string {
  return environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
}

// No `aud` and no `exp`: APNs takes a token for up to an hour from `iat`.
export function providerToken(config: ApnsConfig, now: Date = new Date()): Promise<string> {
  return signES256({ kid: config.keyId }, { iss: config.teamId, iat: Math.floor(now.getTime() / 1000) }, config.privateKey);
}

export interface ProviderTokenStore {
  load(keyId: string): Promise<{ token: string; issuedAt: Date } | null>;
  save(keyId: string, token: string, issuedAt: Date): Promise<void>;
}

// Apple refuses a new token more than once every 20 minutes and an old one after 60, and each run of this function may
// start cold, so the token lives in the database and is replaced after 50 minutes.
export async function cachedProviderToken(
  config: ApnsConfig,
  store: ProviderTokenStore,
  now: Date = new Date(),
): Promise<string> {
  const cached = await store.load(config.keyId);
  const age = cached ? now.getTime() - cached.issuedAt.getTime() : Infinity;
  if (cached && age >= 0 && age < 50 * 60 * 1000) return cached.token;
  const token = await providerToken(config, now);
  await store.save(config.keyId, token, now);
  return token;
}

// The words are fixed: a server push may name a family member by first name, never a dish (decided 2026-11-02).
export function alertFor(kind: string): Alert | null {
  switch (kind) {
    case "plan_set":
      return { title: "This week's dinners are set.", body: "Tap to see the week." };
    default:
      return null;
  }
}

export function payloadFor(alert: Alert, weekStart: string | null): ApnsPayload {
  const payload: ApnsPayload = { aps: { alert, sound: "default" } };
  return weekStart ? { ...payload, route: "week", date: weekStart } : payload;
}

const deadReasons = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

// Deno's fetch speaks HTTP/2 to APNs (it negotiates it over TLS). A network error is worth another try.
export async function deliver(
  device: Device,
  payload: ApnsPayload,
  jwt: string,
  fetchFn: typeof fetch = fetch,
  now: Date = new Date(),
): Promise<DeliveryResult> {
  let response: Response;
  try {
    response = await fetchFn(`${apnsHost(device.environment)}/3/device/${device.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        // A phone that's off for a day has missed the news.
        "apns-expiration": String(Math.floor(now.getTime() / 1000) + 24 * 60 * 60),
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch {
    return "retry";
  }
  if (response.ok) {
    await response.body?.cancel();
    return "delivered";
  }
  const reason = await response.json().then((body: { reason?: unknown }) => body.reason).catch(() => undefined);
  if (response.status === 410 || (typeof reason === "string" && deadReasons.has(reason))) return "dead_token";
  return "retry";
}
