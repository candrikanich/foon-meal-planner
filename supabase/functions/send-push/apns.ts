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

// The routes local reminders use (ReminderPayload in ReminderCenter.swift), so a tap opens the same place.
export type Route =
  | { route: "week"; date: string }
  | { route: "night"; night: string; date: string }
  | { route: "list" }
  | { route: "dinner" }
  | { route: "ideas" }
  // A held kid (#277): the kid's card is at the top of Family.
  | { route: "family" };

export type ApnsPayload = { aps: { alert: Alert; sound: "default" } } & Partial<Route>;

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

const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

// A night's weekday from its date alone. Never "tonight" or "tomorrow": quiet hours can hold a push past the day it was
// written on.
export function weekdayOf(date: string | null): string | null {
  const parts = date?.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!parts) return null;
  const day = new Date(Date.UTC(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3])));
  return Number.isNaN(day.getTime()) ? null : weekdays[day.getUTCDay()];
}

function ideaCount(args: Record<string, unknown>): number | null {
  const count = args.count;
  return typeof count === "number" && Number.isInteger(count) && count > 0 ? count : null;
}

function who(args: Record<string, unknown>): string {
  return firstName(args) ?? "Someone";
}

function firstName(args: Record<string, unknown>): string | null {
  const name = typeof args.name === "string" ? args.name.trim() : "";
  return name === "" ? null : name;
}

// The words are fixed: a server push may name a family member by first name, never a dish (decided 2026-11-02). The name
// is read from args and nothing else is. A kind is known exactly when it has words here.
const words: Record<string, (args: Record<string, unknown>, nightDate: string | null) => Alert | null> = {
  plan_set: () => ({ title: "This week's dinners are set.", body: "Tap to see the week." }),
  // With no name (a kid whose consent was withdrawn is never named), "Someone": the news is still the family's.
  not_home: (args) => ({ title: `${who(args)} won't be home tonight.`, body: "Tap to see tonight." }),
  claim: (args, nightDate) => {
    const weekday = weekdayOf(nightDate);
    return weekday ? { title: `${who(args)} will cook ${weekday}.`, body: "Tap to see the night." } : null;
  },
  // Never the item: whoever's out can check the list.
  urgent_item: (args) => ({ title: `${who(args)} added something for tonight.`, body: "Tap to see the list." }),
  tonight_poll: (args) => ({ title: `${who(args)} started a vote on dinner.`, body: "Tap to vote." }),
  // Someone's at the store now: the words don't say the time, since the push is given up when the run ends.
  heading_to_store: (args) => ({ title: `${who(args)}'s at the store.`, body: "Add anything in the next 10 minutes." }),
  // A planner's digest of new ideas: how many, and who when it's one person. Never a dish.
  new_requests: (args) => {
    const count = ideaCount(args);
    if (!count) return null;
    const name = firstName(args);
    const body = count === 1 ? "Tap to see it." : "Tap to see them.";
    if (name) {
      return { title: count === 1 ? `${name} has a new dinner idea.` : `${name} has ${count} new dinner ideas.`, body };
    }
    return { title: count === 1 ? "1 new dinner idea." : `${count} new dinner ideas.`, body };
  },
  // To every parent when a kid's consent wording is outdated and the kid is signed out (#277). Only with the kid's name:
  // the push is about that kid, and a parent can't act on "Someone".
  agreement_hold: (args) => {
    const name = firstName(args);
    return name
      ? { title: `${name} needs a parent's OK to keep using Foon.`, body: "Open Family to see what changed." }
      : null;
  },
  // To whoever asked, so no name, and never the dish.
  request_planned: (_args, nightDate) => {
    const weekday = weekdayOf(nightDate);
    return weekday ? { title: `Your idea made ${weekday}.`, body: "Tap to see the night." } : null;
  },
};

export const knownKinds: ReadonlySet<string> = new Set(Object.keys(words));

export function alertFor(kind: string, args: Record<string, unknown> = {}, nightDate: string | null = null): Alert | null {
  return Object.hasOwn(words, kind) ? words[kind](args, nightDate) : null;
}

export function payloadFor(alert: Alert, route: Route | null): ApnsPayload {
  const payload: ApnsPayload = { aps: { alert, sound: "default" } };
  return route ? { ...payload, ...route } : payload;
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
