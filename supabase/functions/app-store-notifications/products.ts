// Foon's subscription products, in two groups (Foon/Foon.storekit uses the same ids). Not final: App Store Connect owns
// them. Founding Family is a group of its own so a standard subscriber can't switch to its price from Settings →
// Subscriptions; the app offers it only to founding households. A subscription in either group entitles the household.
export const subscriptionGroups = {
  "Foon Family": ["foon.family.monthly", "foon.family.annual"],
  "Foon Founding Family": ["foon.family.founding"],
} as const;

export type ProductId = typeof subscriptionGroups[keyof typeof subscriptionGroups][number];

const productIds: readonly string[] = Object.values(subscriptionGroups).flat();

export const isFoonProduct = (id: string | undefined): id is ProductId => productIds.includes(id ?? "");
