import { assertEquals } from "@std/assert";
import { decodeEntities, parsePage } from "./recipe.ts";

const page = (jsonLd: unknown, head = "") =>
  `<html><head>${head}<script type="application/ld+json">${JSON.stringify(jsonLd)}</script></head><body></body></html>`;

Deno.test("a plain Recipe block", () => {
  const parsed = parsePage(page({
    "@context": "https://schema.org",
    "@type": "Recipe",
    name: "Weeknight Chili",
    recipeYield: "6 servings",
    recipeIngredient: ["1 lb ground beef", "1 (15 oz) can kidney beans, drained", "2 tbsp chili powder"],
    recipeInstructions: [
      { "@type": "HowToStep", text: "Brown the beef." },
      { "@type": "HowToStep", text: "Add everything and simmer 30 minutes." },
    ],
    image: ["https://example.com/chili.jpg"],
  }));
  assertEquals(parsed.recipe, {
    name: "Weeknight Chili",
    servings: 6,
    ingredients: ["1 lb ground beef", "1 (15 oz) can kidney beans, drained", "2 tbsp chili powder"],
    steps: ["Brown the beef.", "Add everything and simmer 30 minutes."],
    imageURL: "https://example.com/chili.jpg",
  });
});

Deno.test("a recipe inside an @graph with an array @type, sections, and an image object", () => {
  const parsed = parsePage(page({
    "@context": "https://schema.org",
    "@graph": [
      { "@type": "WebPage", name: "Page" },
      {
        "@type": ["Recipe", "NewsArticle"],
        name: "Mac &amp; Cheese",
        recipeYield: [4, "4 bowls"],
        recipeIngredient: ["8 oz elbow macaroni", "2 cups <b>shredded</b> cheddar"],
        recipeInstructions: [
          { "@type": "HowToSection", name: "Pasta", itemListElement: [{ "@type": "HowToStep", text: "Boil." }] },
          { "@type": "HowToSection", name: "Sauce", itemListElement: [{ "@type": "HowToStep", text: "Melt." }] },
        ],
        image: { "@type": "ImageObject", url: "https://example.com/mac.jpg" },
      },
    ],
  }));
  assertEquals(parsed.recipe?.name, "Mac & Cheese");
  assertEquals(parsed.recipe?.servings, 4);
  assertEquals(parsed.recipe?.ingredients, ["8 oz elbow macaroni", "2 cups shredded cheddar"]);
  assertEquals(parsed.recipe?.steps, ["Boil.", "Melt."]);
  assertEquals(parsed.recipe?.imageURL, "https://example.com/mac.jpg");
});

Deno.test("instructions as one string become one step per line", () => {
  const parsed = parsePage(page({
    "@type": "Recipe",
    name: "Toast",
    recipeInstructions: "Toast the bread.\nButter it.\n",
  }));
  assertEquals(parsed.recipe?.steps, ["Toast the bread.", "Butter it."]);
  assertEquals(parsed.recipe?.servings, null);
  assertEquals(parsed.recipe?.imageURL, null);
});

Deno.test("no recipe data falls back to the page title", () => {
  const html = `<html><head><meta property="og:title" content="Grandma&#39;s Pot Roast | Blog">` +
    `<title>Ignored</title><script type="application/ld+json">{not json</script></head></html>`;
  assertEquals(parsePage(html), { recipe: null, title: "Grandma's Pot Roast | Blog", caption: null, captionTruncated: false });
  assertEquals(parsePage("<title> Just a page </title>"), { recipe: null, title: "Just a page", caption: null, captionTruncated: false });
});

Deno.test("a broken block doesn't hide a good one", () => {
  const html = `<script type="application/ld+json">{oops</script>` +
    `<script type='application/ld+json'>${JSON.stringify({ "@type": "Recipe", name: "Tacos" })}</script>`;
  assertEquals(parsePage(html).recipe?.name, "Tacos");
});

Deno.test("only https images, and long lists are capped", () => {
  const parsed = parsePage(page({
    "@type": "Recipe",
    name: "Big batch",
    image: "http://example.com/plain.jpg",
    recipeIngredient: Array.from({ length: 150 }, (_, i) => `${i} thing`),
    recipeInstructions: Array.from({ length: 80 }, (_, i) => `Step ${i}`),
  }));
  assertEquals(parsed.recipe?.imageURL, null);
  assertEquals(parsed.recipe?.ingredients.length, 100);
  assertEquals(parsed.recipe?.steps.length, 50);
});

Deno.test("entities decode, junk ones stay", () => {
  assertEquals(decodeEntities("&frac12; cup &amp; &#x2F; &#47; &bogus; &#0;"), "½ cup & / / &bogus; &#0;");
});

Deno.test("an apostrophe in a double-quoted title stays", () => {
  assertEquals(parsePage(`<meta property="og:title" content="Grandma's Pot Roast">`).title, "Grandma's Pot Roast");
  assertEquals(parsePage(`<meta content='Say "hi"' property='og:title'>`).title, 'Say "hi"');
});

Deno.test("long steps keep their words, and an emoji at the edge isn't split", () => {
  const long = "Stir ".repeat(200).trim();
  const parsed = parsePage(page({
    "@type": "Recipe",
    name: "🌮".repeat(250),
    recipeInstructions: [{ "@type": "HowToStep", text: long }],
  }));
  assertEquals(parsed.recipe?.steps[0], long, "a 1,000-character step is kept whole");
  assertEquals(Array.from(parsed.recipe?.name ?? "").length, 200);
  JSON.parse(JSON.stringify(parsed)); // and it's valid JSON for the app
  assertEquals(new TextEncoder().encode(JSON.stringify(parsed)).length > 0, true);
});

Deno.test("yields that aren't servings aren't used to scale", () => {
  const yieldOf = (recipeYield: unknown) =>
    parsePage(page({ "@type": "Recipe", name: "X", recipeYield })).recipe?.servings;
  assertEquals(yieldOf("Serves 6"), 6);
  assertEquals(yieldOf("4-6 servings"), 4);
  assertEquals(yieldOf("8"), 8);
  assertEquals(yieldOf(["4", "4 servings"]), 4);
  assertEquals(yieldOf("1 (9-inch) pie"), null);
  assertEquals(yieldOf("24 cookies"), null);
});

Deno.test("more entities, and double-encoded ones", () => {
  assertEquals(
    decodeEntities("1&rsquo;s &ndash; caf&eacute; &hellip; &frac13; &amp;#39;"),
    "1\u2019s \u2013 café \u2026 ⅓ '",
  );
});

Deno.test("hostile markup stays fast", () => {
  const started = performance.now();
  parsePage('<meta property="og:title" '.repeat(20_000) + "<script type=application/ld+json>".repeat(20_000));
  const elapsed = performance.now() - started;
  assertEquals(elapsed < 1000, true, `took ${elapsed} ms`);
});

Deno.test("recipes nested in mainEntity and sections within sections", () => {
  const parsed = parsePage(page({
    "@type": "WebPage",
    mainEntity: {
      "@type": "Recipe",
      name: "Lasagna",
      recipeInstructions: [{
        "@type": "HowToSection",
        itemListElement: [{ "@type": "HowToSection", itemListElement: [{ "@type": "HowToStep", text: "Layer." }] }],
      }],
    },
  }));
  assertEquals(parsed.recipe?.steps, ["Layer."]);
});

Deno.test("a caption keeps its line breaks, and decodes", () => {
  const html = `<meta property="og:description" content="Chili &amp; rice\n\n1 lb beef\r\n  2 cups   rice">`;
  assertEquals(parsePage(html).caption, "Chili & rice\n1 lb beef\n2 cups rice");
});

Deno.test("the plain description is the fallback, and a caption is bounded", () => {
  assertEquals(parsePage(`<meta name="description" content='Say "hi"'>`).caption, 'Say "hi"');
  assertEquals(parsePage("<title>x</title>").caption, null);
  const whole = parsePage(`<meta property="og:description" content="${"x".repeat(2200)}">`);
  assertEquals(whole.caption?.length, 2200, "Instagram's longest arrives whole");
  assertEquals(whole.captionTruncated, false);
});

Deno.test("a caption too long to keep says so, and never ends on half a line", () => {
  const lines = Array.from({ length: 200 }, (_, i) => `${i} cups peanut butter`).join("\n");
  const page = parsePage(`<meta property="og:description" content="${lines}">`);
  assertEquals(page.captionTruncated, true);
  assertEquals(page.caption?.endsWith("peanut butter"), true);
  assertEquals((page.caption?.length ?? 0) <= 3000, true);
});

Deno.test("a caption too long even to read is no caption, so it stays an idea", () => {
  const page = parsePage(`<meta property="og:description" content="${"x".repeat(9000)}">`);
  assertEquals(page.caption, null);
});

Deno.test("a title running over several lines is still the title", () => {
  const html = `<meta property="og:title" content="Cook on Instagram: &quot;Beef biscuits are great.\n\nFlaky and golden">`;
  assertEquals(parsePage(html).title, 'Cook on Instagram: "Beef biscuits are great. Flaky and golden');
});
