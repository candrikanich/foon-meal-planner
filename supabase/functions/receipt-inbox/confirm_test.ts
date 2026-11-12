import { assertEquals } from "@std/assert";
import { sha256 } from "../_shared/token.ts";
import { confirmOrigins, type ConfirmDeps, handleConfirm } from "./confirm.ts";

const TOKEN = "Abc_DEF-0123456789abcdefghijkl";

function fakeDeps(answer: string | Error = "confirmed") {
  const confirmed: string[] = [];
  const deps: ConfirmDeps = {
    allowedOrigins: ["https://getfoon.com"],
    siteUrl: "https://getfoon.com/",
    confirm: (tokenHash) => {
      confirmed.push(tokenHash);
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
    },
    log: () => {},
  };
  return { deps, confirmed };
}

const request = (token: string, method: string, headers: Record<string, string> = { Origin: "https://getfoon.com" }) =>
  new Request(`https://x.supabase.co/functions/v1/receipt-inbox?confirm=${encodeURIComponent(token)}`, {
    method,
    headers,
  });

Deno.test("opening the link changes nothing: it goes to the site's page", async () => {
  const { deps, confirmed } = fakeDeps();
  const response = await handleConfirm(request(TOKEN, "GET", {}), TOKEN, deps);
  assertEquals(response.status, 303);
  assertEquals(response.headers.get("Location"), `https://getfoon.com/receipts/confirm?t=${TOKEN}`);
  assertEquals(confirmed, []);
});

Deno.test("the site's button confirms with the token's hash", async () => {
  const { deps, confirmed } = fakeDeps();
  const response = await handleConfirm(request(TOKEN, "POST"), TOKEN, deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { outcome: "confirmed" });
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://getfoon.com");
  assertEquals(confirmed, [await sha256(TOKEN)]);
});

Deno.test("the database's answers pass through; anything else reads as unknown", async () => {
  for (const [answer, outcome] of [["expired", "expired"], ["unknown", "unknown"], ["already", "unknown"]]) {
    const { deps } = fakeDeps(answer);
    assertEquals(await (await handleConfirm(request(TOKEN, "POST"), TOKEN, deps)).json(), { outcome });
  }
  const { deps } = fakeDeps(new Error("down"));
  assertEquals((await handleConfirm(request(TOKEN, "POST"), TOKEN, deps)).status, 500);
});

Deno.test("only the site may POST, and only a token-shaped token", async () => {
  const { deps, confirmed } = fakeDeps();
  assertEquals((await handleConfirm(request(TOKEN, "POST", {}), TOKEN, deps)).status, 403);
  assertEquals((await handleConfirm(request(TOKEN, "POST", { Origin: "https://evil.example" }), TOKEN, deps)).status, 403);
  assertEquals((await handleConfirm(request("short", "POST"), "short", deps)).status, 400);
  assertEquals((await handleConfirm(request(TOKEN, "PUT"), TOKEN, deps)).status, 405);
  assertEquals(confirmed, []);
  const preflight = await handleConfirm(request(TOKEN, "OPTIONS"), TOKEN, deps);
  assertEquals(preflight.status, 204);
  assertEquals(preflight.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
});

Deno.test("the allowed origins add the configured site", () => {
  assertEquals(confirmOrigins("https://staging.getfoon.com/x").at(-1), "https://staging.getfoon.com");
  assertEquals(confirmOrigins("https://getfoon.com"), confirmOrigins(undefined));
  assertEquals(confirmOrigins("not a url"), confirmOrigins(undefined));
});
