import { assertEquals } from "@std/assert";
import { BlockedURL, PageUnavailable } from "./fetch.ts";
import { handleImport } from "./handler.ts";

const token = (claims: Record<string, unknown>) =>
  `h.${btoa(JSON.stringify(claims)).replaceAll("=", "").replaceAll("+", "-").replaceAll("/", "_")}.s`;
const signedIn = token({ role: "authenticated", sub: "user-1" });

const request = (body: unknown, jwt: string | null = signedIn) =>
  new Request("http://localhost/import-recipe", {
    method: "POST",
    headers: jwt ? { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" } : {},
    body: JSON.stringify(body),
  });

const recipePage = `<script type="application/ld+json">${
  JSON.stringify({ "@type": "Recipe", name: "Tacos", recipeYield: 4, recipeIngredient: ["1 lb beef"] })
}</script>`;

Deno.test("returns the recipe and where the page ended up", async () => {
  const response = await handleImport(request({ url: " https://r.example/tacos " }), {
    fetchPage: (link) => Promise.resolve({ html: recipePage, url: `${link}?final` }),
    log: () => {},
  });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.recipe.name, "Tacos");
  assertEquals(body.recipe.servings, 4);
  assertEquals(body.url, "https://r.example/tacos?final");
});

Deno.test("no recipe data is still a 200, with the title", async () => {
  const response = await handleImport(request({ url: "https://r.example/post" }), {
    fetchPage: () => Promise.resolve({ html: "<title>A post</title>", url: "https://r.example/post" }),
    log: () => {},
  });
  assertEquals(await response.json(), { recipe: null, title: "A post", url: "https://r.example/post" });
});

Deno.test("blocked and unreachable links say which", async () => {
  const blocked = await handleImport(request({ url: "http://10.0.0.1" }), {
    fetchPage: () => Promise.reject(new BlockedURL("private address")),
    log: () => {},
  });
  assertEquals(blocked.status, 400);
  assertEquals(await blocked.json(), { error: "url_not_allowed" });
  const down = await handleImport(request({ url: "https://r.example/down" }), {
    fetchPage: () => Promise.reject(new PageUnavailable("status 503")),
    log: () => {},
  });
  assertEquals(down.status, 502);
});

Deno.test("needs a session and a link", async () => {
  const deps = { fetchPage: () => Promise.reject(new Error("not called")), log: () => {} };
  assertEquals((await handleImport(request({ url: "https://r.example" }, null), deps)).status, 401);
  assertEquals(
    (await handleImport(request({ url: "https://r.example" }, token({ role: "anon" })), deps)).status,
    401,
    "the app's anon key isn't a signed-in person",
  );
  assertEquals((await handleImport(request({ url: "https://r.example" }, "not-a-jwt"), deps)).status, 401);
  assertEquals((await handleImport(request({}), deps)).status, 400);
  assertEquals((await handleImport(request({ url: 7 }), deps)).status, 400);
  assertEquals(
    (await handleImport(new Request("http://localhost/import-recipe", { method: "GET" }), deps)).status,
    405,
  );
});
