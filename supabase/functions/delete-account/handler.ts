// delete-account: deletes the caller's account or, with `scope: "household"`, only the household they own (the
// owner starts over and keeps their account; no Apple step). For an account the order matters: Apple first, so a
// refused revocation leaves everything as it was. Then the household's photos, then the database, then the auth user
// last. A failure part-way can be retried: each step is safe to run again.

import { AppleAccountMismatch } from "./apple.ts";

export interface DeleteAccountDeps {
  userFromToken(jwt: string): Promise<string | null>;
  // The Apple ID (`sub`) the account signed in with; null if it has none.
  appleSubject(userID: string): Promise<string | null>;
  revokeAppleToken(authorizationCode: string, appleSubject: string): Promise<void>;
  // The household this person owns, if any (deleting the owner's account deletes it).
  ownedHousehold(userID: string): Promise<string | null>;
  removeHouseholdPhotos(householdID: string): Promise<void>;
  // `delete_account_data`: returns what it did.
  deleteAccountData(userID: string): Promise<string>;
  // `delete_household_data`: erases the household this person owns.
  deleteHouseholdData(userID: string): Promise<string>;
  deleteUser(userID: string): Promise<void>;
  log(message: string, error?: unknown): void;
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handleDeleteAccount(req: Request, deps: DeleteAccountDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const jwt = req.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1];
  const userID = jwt ? await deps.userFromToken(jwt).catch(() => null) : null;
  if (!userID) return json(401, { error: "not_signed_in" });

  const body = await req.json().catch(() => null) as { authorization_code?: unknown; scope?: unknown } | null;
  if (body?.scope === "household") return deleteHousehold(userID, deps);
  const code = body?.authorization_code;
  if (typeof code !== "string" || code.length === 0 || code.length > 2048) {
    return json(400, { error: "authorization_code_required" });
  }

  try {
    const subject = await deps.appleSubject(userID);
    if (!subject) return json(409, { error: "apple_account_mismatch" });
    await deps.revokeAppleToken(code, subject);
  } catch (error) {
    if (error instanceof AppleAccountMismatch) return json(409, { error: "apple_account_mismatch" });
    deps.log("apple revocation failed", error);
    return json(502, { error: "apple_revoke_failed" });
  }

  try {
    const household = await deps.ownedHousehold(userID);
    if (household) await deps.removeHouseholdPhotos(household);
    const result = await deps.deleteAccountData(userID);
    await deps.deleteUser(userID);
    return json(200, { result });
  } catch (error) {
    deps.log("account deletion failed", error);
    return json(500, { error: "delete_failed" });
  }
}

// Photos first, then the data: a failure part-way leaves the household in place, and a retry finishes it.
async function deleteHousehold(userID: string, deps: DeleteAccountDeps): Promise<Response> {
  try {
    const household = await deps.ownedHousehold(userID);
    if (!household) return json(403, { error: "not_owner" });
    await deps.removeHouseholdPhotos(household);
    const result = await deps.deleteHouseholdData(userID);
    // Ownership moved between the check and the delete: say so rather than report success.
    if (result !== "household_deleted") return json(403, { error: "not_owner" });
    return json(200, { result });
  } catch (error) {
    deps.log("household deletion failed", error);
    return json(500, { error: "delete_failed" });
  }
}
