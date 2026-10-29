// Deletes the caller's account (#29), or only the household they own. Needs the service role (only here, never in the
// app) and the Sign in with Apple key as secrets: APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID (the bundle id),
// APPLE_PRIVATE_KEY.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { appleConfigFromEnv, revokeAppleToken } from "./apple.ts";
import { handleDeleteAccount } from "./handler.ts";

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`${key} is not set`);
  return value;
}

const admin = createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const apple = appleConfigFromEnv((key) => Deno.env.get(key));
const bucket = "household-photos";

// Every object under the household's folder; Storage lists one level at a time.
async function householdPhotoPaths(client: SupabaseClient, folder: string): Promise<string[]> {
  const paths: string[] = [];
  for (let offset = 0;; offset += 1000) {
    const { data, error } = await client.storage.from(bucket).list(folder, { limit: 1000, offset });
    if (error) throw error;
    for (const entry of data) {
      const path = `${folder}/${entry.name}`;
      // Folders come back without an id.
      if (entry.id === null) paths.push(...await householdPhotoPaths(client, path));
      else paths.push(path);
    }
    if (data.length < 1000) return paths;
  }
}

Deno.serve((req) =>
  handleDeleteAccount(req, {
    userFromToken: async (jwt) => (await admin.auth.getUser(jwt)).data.user?.id ?? null,
    appleSubject: async (userID) => {
      const { data, error } = await admin.auth.admin.getUserById(userID);
      if (error) throw error;
      const identity = data.user.identities?.find((identity) => identity.provider === "apple");
      return (identity?.identity_data?.sub as string | undefined) ?? identity?.id ?? null;
    },
    revokeAppleToken: (code, subject) => {
      if (!apple) throw new Error("Sign in with Apple secrets are not set");
      return revokeAppleToken(code, subject, apple);
    },
    ownedHousehold: async (userID) => {
      const { data, error } = await admin.from("households").select("id").eq("owner", userID).maybeSingle();
      if (error) throw error;
      return data?.id ?? null;
    },
    removeHouseholdPhotos: async (householdID) => {
      const paths = await householdPhotoPaths(admin, householdID);
      for (let i = 0; i < paths.length; i += 1000) {
        const { error } = await admin.storage.from(bucket).remove(paths.slice(i, i + 1000));
        if (error) throw error;
      }
    },
    deleteAccountData: async (userID) => {
      const { data, error } = await admin.rpc("delete_account_data", { target_user: userID });
      if (error) throw error;
      return data as string;
    },
    deleteHouseholdData: async (userID) => {
      const { data, error } = await admin.rpc("delete_household_data", { target_user: userID });
      if (error) throw error;
      return data as string;
    },
    deleteUser: async (userID) => {
      const { error } = await admin.auth.admin.deleteUser(userID);
      if (error) throw error;
    },
    // Ids and status codes only: no names, tokens, or household data in logs.
    log: (message, error) => console.error(message, error instanceof Error ? error.message : error),
  })
);
