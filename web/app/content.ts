// Everything the pages say about Foon lives here, so copy changes in one place and the spec stays the source of truth.
export const SUPPORT_EMAIL = "support@getfoon.com";
// The same mailbox is in the waitlist email footer (supabase/functions/waitlist/email.ts) and docs/legal Contact.
export const POSTAL_ADDRESS = ["34125 Center Ridge Road #1012", "North Ridgeville, OH 44039"] as const;
export const PRIVACY_UPDATED = "November 7, 2026";

export const mission = "Take the weight of dinner off one person and share it with the whole family.";
export const tagline = "Dinner, planned together.";

export const beats = [
  {
    title: "Sunday, ten minutes",
    body: "Foon drafts the week from the dishes your family already likes. The planner swaps a night or two, approves it, and that is the whole job.",
  },
  {
    title: "The whole family pitches in",
    body: "Everyone can say what sounds good, claim a night to cook, or ask for a dish. The planner edits a plan instead of inventing one.",
  },
  {
    title: "The shopping list builds itself",
    body: "Approve the week and the list is ready. Quick adds from anyone in the family land on it too, so nothing gets texted around.",
  },
  {
    title: "Store mode",
    body: "Aisles in walking order, big rows, and checked items drop into the cart. Anyone in the family can pick up the list.",
  },
] as const;

export const screenshots = [
  { file: "this-week.png", alt: "The week's dinners as cards, one for each night", caption: "This week" },
  { file: "pitch-in.png", alt: "A family member picking dishes they would like this week", caption: "Everyone pitches in" },
  { file: "shopping-list.png", alt: "The shopping list in store mode", caption: "The shopping list" },
] as const;

export const foundingOffer = {
  heading: "Founding families",
  summary: "Be one of our first 50 families.",
  points: [
    "Free while Foon is in beta.",
    "Then half price on the annual plan: $24.99 a year instead of $49.99.",
    "That price is locked for life, with no increases.",
  ],
  fineprint:
    "Foon is built for the whole family, so the waitlist is for adults. We close the founding spots after 50 families, or a year, whichever comes first.",
} as const;
