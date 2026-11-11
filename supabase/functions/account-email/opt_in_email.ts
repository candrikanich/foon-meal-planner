// The two emails an adult opts in to (#48, PR C): the weekly plan email and founding-family updates. Both end with the
// sender, a postal address, why they're getting it and an unsubscribe link, and carry the one-click unsubscribe headers.
// English only. The weekly plan email names only the household's own dishes; founding updates are Chris's words.
import { type Block, blocksEmail, commercialFooter, unsubscribeHeaders } from "../_shared/email_layout.ts";
import type { Email } from "../_shared/resend.ts";

type Message = Omit<Email, "to">;

// The emails someone can opt in to, as the preference and the unsubscribe link name them.
export const OPT_IN_KINDS = ["weekly_plan", "founding_updates"] as const;
export type OptInKind = typeof OPT_IN_KINDS[number];

// Weekly plan -----------------------------------------------------------------------------------------------------------

export interface PlanNight {
  date: string;
  meal: string | null;
  quickPick: string | null;
  away: boolean;
}

export interface WeeklyPlanDetails {
  weekStart: string;
  nights: PlanNight[];
}

const dayPattern = /^\d{4}-\d{2}-\d{2}$/;

// What account_email_weekly_plan returned, or null when it isn't a week.
export function weeklyPlanDetails(value: unknown): WeeklyPlanDetails | null {
  if (typeof value !== "object" || value === null) return null;
  const { week_start: weekStart, nights } = value as Record<string, unknown>;
  if (typeof weekStart !== "string" || !dayPattern.test(weekStart) || !Array.isArray(nights)) return null;
  return {
    weekStart,
    nights: nights.flatMap((night) => {
      if (typeof night !== "object" || night === null) return [];
      const { date, meal, quick_pick: quickPick, away } = night as Record<string, unknown>;
      if (typeof date !== "string" || !dayPattern.test(date)) return [];
      return [{
        date,
        meal: typeof meal === "string" ? meal : null,
        quickPick: typeof quickPick === "string" ? quickPick : null,
        away: away === true,
      }];
    }),
  };
}

const quickPicks: Record<string, string> = {
  leftovers: "Leftovers",
  takeout: "Takeout",
  eat_out: "Eat out",
  fend_for_yourselves: "Fend for yourselves",
  freezer_raid: "Freezer raid",
};

// A calendar day, never shifted by a time zone: "Monday, November 16".
function dayName(day: string, withWeekday = true): string {
  return new Date(`${day}T12:00:00Z`).toLocaleDateString("en-US", {
    timeZone: "UTC",
    ...(withWeekday ? { weekday: "long" } : {}),
    month: "long",
    day: "numeric",
  });
}

// One line per night. A dish's name is the family's own text: on one line, and escaped in the HTML by the renderer.
export function nightLine(night: PlanNight): string {
  const dinner = night.meal?.replace(/\s+/g, " ").trim() ||
    (night.quickPick ? quickPicks[night.quickPick] : undefined) ||
    (night.away ? "Away" : "Nothing planned yet");
  return `${dayName(night.date)}: ${dinner}`;
}

export function weeklyPlanEmail(
  details: WeeklyPlanDetails,
  links: { siteUrl: string; unsubscribeUrl: string },
): Message {
  const footer = commercialFooter(
    links.unsubscribeUrl,
    "turns off this weekly email",
    undefined,
    "You're getting this because you turned on the weekly plan email in Foon (Family, then Email).",
  );
  return {
    ...blocksEmail(`Your family's dinners for the week of ${dayName(details.weekStart, false)}`, [
      "Hi,",
      "Your family's week is set. Here's what's for dinner:",
      { list: details.nights.map(nightLine) },
      "Plans can change: Foon always has the latest, with who's cooking and the shopping list.",
      `Open Foon: ${links.siteUrl.replace(/\/+$/, "")}`,
    ], footer),
    headers: unsubscribeHeaders(links.unsubscribeUrl),
  };
}

// Founding-family updates -------------------------------------------------------------------------------------------------

export interface FoundingUpdate {
  subject: string;
  body: string;
}

export const MAX_SUBJECT = 150;
export const MAX_BODY = 20_000;

// What the Action sent: a markdown file whose first line is "# Subject", or a subject and a body. A typed subject wins
// over the file's. Null when there's no one-line subject or no body, or either is too long.
export function parseUpdate(input: unknown): FoundingUpdate | null {
  if (typeof input !== "object" || input === null) return null;
  const { subject, body, markdown } = input as Record<string, unknown>;
  let fileSubject: string | undefined;
  let text = typeof body === "string" ? body : undefined;
  if (typeof markdown === "string") {
    const [first, ...rest] = markdown.replace(/\r\n/g, "\n").trim().split("\n");
    const heading = first.match(/^#\s+(.+)$/);
    if (!heading) return null;
    fileSubject = heading[1];
    text = rest.join("\n");
  }
  const finalSubject = (typeof subject === "string" && subject.trim() ? subject : fileSubject)?.trim();
  const finalBody = text?.trim();
  if (!finalSubject || !finalBody || /[\r\n]/.test(finalSubject)) return null;
  if (finalSubject.length > MAX_SUBJECT || finalBody.length > MAX_BODY) return null;
  return { subject: finalSubject, body: finalBody };
}

// A plain subset of markdown: blank lines split paragraphs, lines starting "- " or "* " are a list, a heading's #s go.
// Links stay as text (mail apps make them links); nothing is ever written out as HTML.
export function bodyBlocks(body: string): Block[] {
  return body.replace(/\r\n/g, "\n").split(/\n\s*\n/).flatMap((chunk): Block[] => {
    const lines = chunk.split("\n").map((line) => line.trim()).filter(Boolean);
    if (lines.length === 0) return [];
    if (lines.every((line) => /^[-*]\s+/.test(line))) {
      return [{ list: lines.map((line) => line.replace(/^[-*]\s+/, "")) }];
    }
    return [lines.map((line) => line.replace(/^#+\s*/, "")).join(" ")];
  });
}

// EMAIL_POSTAL_ADDRESS, its lines split by ";" or newlines. Null when unset: then no marketing email goes.
export function parsePostalAddress(value: string | undefined): string[] | null {
  const lines = (value ?? "").split(/;|\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines.length > 0 ? lines : null;
}

export function foundingUpdateEmail(
  update: FoundingUpdate,
  links: { unsubscribeUrl: string; postalAddress: readonly string[] },
): Message {
  const footer = commercialFooter(
    links.unsubscribeUrl,
    "turns off founding-family updates",
    links.postalAddress,
    "You're getting this because you turned on founding-family updates in Foon (Family, then Email).",
  );
  return {
    ...blocksEmail(update.subject, bodyBlocks(update.body), footer),
    headers: unsubscribeHeaders(links.unsubscribeUrl),
  };
}
