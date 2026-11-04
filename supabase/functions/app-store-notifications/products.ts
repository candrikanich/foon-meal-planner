// The Foon Family subscription group. Not final: App Store Connect owns the ids, and Foon/Foon.storekit uses the same ones.
export const productIds = ["foon.family.monthly", "foon.family.annual", "foon.family.founding"] as const;

export type ProductId = typeof productIds[number];

export const isFoonProduct = (id: string | undefined): id is ProductId =>
  (productIds as readonly string[]).includes(id ?? "");
