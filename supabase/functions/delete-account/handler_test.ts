import { assertEquals } from "@std/assert";
import { AppleAccountMismatch } from "./apple.ts";
import { type DeleteAccountDeps, handleDeleteAccount } from "./handler.ts";

function fakeDeps(overrides: Partial<DeleteAccountDeps> = {}): { deps: DeleteAccountDeps; steps: string[] } {
  const steps: string[] = [];
  const deps: DeleteAccountDeps = {
    userFromToken: (jwt) => Promise.resolve(jwt === "good" ? "user-1" : null),
    appleSubject: () => Promise.resolve("apple-1"),
    revokeAppleToken: (code, subject) => {
      steps.push(`revoke ${code} ${subject}`);
      return Promise.resolve();
    },
    ownedHousehold: () => Promise.resolve(null),
    removeHouseholdPhotos: (household) => {
      steps.push(`photos ${household}`);
      return Promise.resolve();
    },
    deleteAccountData: (user) => {
      steps.push(`data ${user}`);
      return Promise.resolve("profile_anonymized");
    },
    deleteHouseholdData: (user) => {
      steps.push(`household data ${user}`);
      return Promise.resolve("household_deleted");
    },
    deleteUser: (user) => {
      steps.push(`user ${user}`);
      return Promise.resolve();
    },
    log: () => {},
    ...overrides,
  };
  return { deps, steps };
}

const request = (body: unknown, token = "good") =>
  new Request("http://localhost/delete-account", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("revokes with Apple, then deletes the data, then the account", async () => {
  const { deps, steps } = fakeDeps();
  const response = await handleDeleteAccount(request({ authorization_code: "c1" }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "profile_anonymized" });
  assertEquals(steps, ["revoke c1 apple-1", "data user-1", "user user-1"]);
});

Deno.test("an owner's household photos go before the household", async () => {
  const { deps, steps } = fakeDeps({ ownedHousehold: () => Promise.resolve("house-1") });
  await handleDeleteAccount(request({ authorization_code: "c1" }), deps);
  assertEquals(steps, ["revoke c1 apple-1", "photos house-1", "data user-1", "user user-1"]);
});

Deno.test("a refused revocation deletes nothing", async () => {
  const { deps, steps } = fakeDeps({ revokeAppleToken: () => Promise.reject(new Error("invalid_grant")) });
  const response = await handleDeleteAccount(request({ authorization_code: "old" }), deps);
  assertEquals(response.status, 502);
  assertEquals(steps, []);
});

Deno.test("a failed data delete keeps the account, so a retry can finish", async () => {
  const { deps, steps } = fakeDeps({ deleteAccountData: () => Promise.reject(new Error("db down")) });
  const response = await handleDeleteAccount(request({ authorization_code: "c1" }), deps);
  assertEquals(response.status, 500);
  assertEquals(steps, ["revoke c1 apple-1"]);
});

Deno.test("needs a signed-in caller and an authorization code", async () => {
  const { deps, steps } = fakeDeps();
  assertEquals((await handleDeleteAccount(request({ authorization_code: "c1" }, "bad"), deps)).status, 401);
  assertEquals((await handleDeleteAccount(request({}), deps)).status, 400);
  assertEquals((await handleDeleteAccount(request({ authorization_code: 42 }), deps)).status, 400);
  assertEquals(
    (await handleDeleteAccount(new Request("http://localhost/delete-account", { method: "GET" }), deps)).status,
    405,
  );
  assertEquals(steps, []);
});

Deno.test("another Apple ID's code deletes nothing", async () => {
  const { deps, steps } = fakeDeps({ revokeAppleToken: () => Promise.reject(new AppleAccountMismatch()) });
  const response = await handleDeleteAccount(request({ authorization_code: "c1" }), deps);
  assertEquals(response.status, 409);
  assertEquals(await response.json(), { error: "apple_account_mismatch" });
  assertEquals(steps, []);
});

Deno.test("an account without an Apple ID can't be confirmed with one", async () => {
  const { deps, steps } = fakeDeps({ appleSubject: () => Promise.resolve(null) });
  assertEquals((await handleDeleteAccount(request({ authorization_code: "c1" }), deps)).status, 409);
  assertEquals(steps, []);
});

Deno.test("a failed account delete after the data is gone is a 500 a retry finishes", async () => {
  const { deps, steps } = fakeDeps({ deleteUser: () => Promise.reject(new Error("auth down")) });
  const response = await handleDeleteAccount(request({ authorization_code: "c1" }), deps);
  assertEquals(response.status, 500);
  assertEquals(steps, ["revoke c1 apple-1", "data user-1"]);
});

Deno.test("delete household: photos, then the household; no Apple step, and the account stays", async () => {
  const { deps, steps } = fakeDeps({ ownedHousehold: () => Promise.resolve("house-1") });
  const response = await handleDeleteAccount(request({ scope: "household" }), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { result: "household_deleted" });
  assertEquals(steps, ["photos house-1", "household data user-1"]);
});

Deno.test("delete household: only the owner, and only when signed in", async () => {
  const { deps, steps } = fakeDeps();
  assertEquals((await handleDeleteAccount(request({ scope: "household" }), deps)).status, 403);
  assertEquals((await handleDeleteAccount(request({ scope: "household" }, "bad"), deps)).status, 401);
  assertEquals(steps, []);
});

Deno.test("delete household: a failed photo removal deletes no data, so a retry can finish", async () => {
  const { deps, steps } = fakeDeps({
    ownedHousehold: () => Promise.resolve("house-1"),
    removeHouseholdPhotos: () => Promise.reject(new Error("storage down")),
  });
  assertEquals((await handleDeleteAccount(request({ scope: "household" }), deps)).status, 500);
  assertEquals(steps, []);
});

Deno.test("delete household: a failed data delete is an error, so a retry can finish", async () => {
  const { deps, steps } = fakeDeps({
    ownedHousehold: () => Promise.resolve("house-1"),
    deleteHouseholdData: () => Promise.reject(new Error("db down")),
  });
  assertEquals((await handleDeleteAccount(request({ scope: "household" }), deps)).status, 500);
  assertEquals(steps, ["photos house-1"]);
});

Deno.test("delete household: ownership moving mid-way isn't reported as deleted", async () => {
  const { deps } = fakeDeps({
    ownedHousehold: () => Promise.resolve("house-1"),
    deleteHouseholdData: () => Promise.resolve("not_owner"),
  });
  assertEquals((await handleDeleteAccount(request({ scope: "household" }), deps)).status, 403);
});
