import { assert, assertEquals, assertRejects } from "@std/assert";
import { BlockedURL, fetchPage, isPrivateAddress, PageUnavailable } from "./fetch.ts";

const html = (status = 200, headers: Record<string, string> = { "Content-Type": "text/html; charset=utf-8" }) =>
  new Response("<title>Hi</title>", { status, headers });

function deps(routes: Record<string, () => Response>, dns: Record<string, string[]> = {}) {
  // DNS answers can be IPv6 too; a mapped private address there is caught by the same check.
  const requested: string[] = [];
  return {
    requested,
    deps: {
      fetch: ((input: string | URL | Request) => {
        const url = String(input);
        requested.push(url);
        const route = routes[url];
        return route ? Promise.resolve(route()) : Promise.reject(new TypeError("unreachable"));
      }) as typeof fetch,
      resolve: (host: string) => Promise.resolve(dns[host] ?? ["93.184.215.14"]),
    },
  };
}

Deno.test("private, loopback, link-local, and metadata addresses are private", () => {
  for (
    const ip of [
      "127.0.0.1",
      "10.1.2.3",
      "172.16.0.1",
      "192.168.1.1",
      "169.254.169.254",
      "0.0.0.0",
      "::1",
      "fd00::1",
      "fe80::1",
      "::ffff:10.0.0.1",
      "100.64.0.1",
    ]
  ) {
    assert(isPrivateAddress(ip), ip);
  }
  for (const ip of ["::ffff:7f00:1", "::ffff:a9fe:a9fe", "::7f00:1", "64:ff9b::a00:1", "2002:a00:1::", "fec0::1"]) {
    assert(isPrivateAddress(ip), ip);
  }
  for (const ip of ["93.184.215.14", "8.8.8.8", "2606:4700::1111", "172.32.0.1", "::ffff:5db8:d70e"]) {
    assert(!isPrivateAddress(ip), ip);
  }
});

Deno.test("fetches a page", async () => {
  const { deps: d } = deps({ "https://recipes.example/chili": () => html() });
  const page = await fetchPage("https://recipes.example/chili", d);
  assertEquals(page, { html: "<title>Hi</title>", url: "https://recipes.example/chili" });
});

Deno.test("refuses links into private networks, by name or after DNS", async () => {
  const { deps: d, requested } = deps({}, { "sneaky.example": ["10.0.0.5"] });
  for (
    const link of [
      "http://localhost/admin",
      "http://127.0.0.1/",
      "http://[::1]/",
      "http://[::ffff:127.0.0.1]/",
      "http://[::ffff:a9fe:a9fe]/latest/meta-data/",
      "http://[::7f00:1]/",
      "http://2130706433/",
      "http://0177.0.0.1/",
      "http://127.0.0.1./",
      "http://169.254.169.254/latest/meta-data",
      "https://sneaky.example/",
      "https://printer.local/",
      "ftp://recipes.example/",
      "https://user:pass@recipes.example/",
      "https://recipes.example:8443/",
      "not a link",
    ]
  ) {
    await assertRejects(() => fetchPage(link, d), BlockedURL, undefined, link);
  }
  assertEquals(requested, [], "nothing was fetched");
});

Deno.test("a redirect into a private network is refused", async () => {
  const { deps: d, requested } = deps({
    "https://recipes.example/short": () =>
      new Response(null, { status: 302, headers: { Location: "http://10.0.0.1/" } }),
  });
  await assertRejects(() => fetchPage("https://recipes.example/short", d), BlockedURL);
  assertEquals(requested, ["https://recipes.example/short"]);
});

Deno.test("redirects are followed, a few at most", async () => {
  const { deps: d } = deps({
    "https://recipes.example/a": () => new Response(null, { status: 301, headers: { Location: "/b" } }),
    "https://recipes.example/b": () => html(),
  });
  assertEquals((await fetchPage("https://recipes.example/a", d)).url, "https://recipes.example/b");

  const loop = deps({
    "https://recipes.example/loop": () => new Response(null, { status: 302, headers: { Location: "/loop" } }),
  });
  await assertRejects(() => fetchPage("https://recipes.example/loop", loop.deps), PageUnavailable);
});

Deno.test("not a web page, missing, or unreachable is unavailable", async () => {
  const { deps: d } = deps({
    "https://recipes.example/photo.jpg": () => html(200, { "Content-Type": "image/jpeg" }),
    "https://recipes.example/gone": () => html(404),
  });
  await assertRejects(() => fetchPage("https://recipes.example/photo.jpg", d), PageUnavailable);
  await assertRejects(() => fetchPage("https://recipes.example/gone", d), PageUnavailable);
  await assertRejects(() => fetchPage("https://recipes.example/down", d), PageUnavailable);
});

Deno.test("huge pages are cut off at the cap", async () => {
  const big = "<title>Big</title>" + "x".repeat(3_000_000);
  const { deps: d } = deps({
    "https://recipes.example/big": () => new Response(big, { headers: { "Content-Type": "text/html" } }),
  });
  const page = await fetchPage("https://recipes.example/big", d);
  assert(page.html.length <= 2_000_000);
  assert(page.html.startsWith("<title>Big</title>"));
});

Deno.test("a name that resolves to a mapped private IPv6 address is refused", async () => {
  const { deps: d } = deps({}, { "rebind.example": ["::ffff:a9fe:a9fe"] });
  await assertRejects(() => fetchPage("https://rebind.example/", d), BlockedURL);
});
