// Reads schema.org Recipe data (JSON-LD) out of a recipe page. Pure, so it's tested against saved page shapes.

export interface Recipe {
  name: string;
  servings: number | null;
  ingredients: string[];
  steps: string[];
  imageURL: string | null;
}

export interface ParsedPage {
  recipe: Recipe | null;
  // The page's own title, for saving just the title and link when there's no recipe data.
  title: string | null;
  // The page's description (a social post's caption), with its line breaks. The app looks for a recipe in it.
  caption: string | null;
  // Cut to fit: an ingredient may be missing, and the app says so, since allergy flags only see what's kept.
  captionTruncated: boolean;
}

const maxIngredients = 100;
const maxSteps = 50;
const maxLine = 300;
// Steps run long on real sites; the app takes up to 20,000 characters of steps in all.
const maxStep = 2000;
const maxBlocks = 20;
// The title lives in <head>; never scan a whole 2 MB page for it.
const headBytes = 100_000;
// Above the longest caption the big platforms allow (Instagram's 2,200), so real ones arrive whole.
const maxCaption = 3000;

export function parsePage(html: string): ParsedPage {
  const recipe = jsonLdBlocks(html).map(findRecipe).find((node) => node !== null);
  const caption = pageCaption(html);
  return {
    recipe: recipe ? toRecipe(recipe) : null,
    title: pageTitle(html),
    caption: caption ? fitCaption(caption) : null,
    captionTruncated: (caption?.length ?? 0) > maxCaption,
  };
}

// A linear scan (indexOf), not a regex over the page: hostile HTML can't make it slow.
function jsonLdBlocks(html: string): unknown[] {
  const blocks: unknown[] = [];
  const lower = html.toLowerCase();
  let from = 0;
  while (blocks.length < maxBlocks) {
    const open = lower.indexOf("<script", from);
    if (open < 0) break;
    const tagEnd = lower.indexOf(">", open);
    if (tagEnd < 0) break;
    const close = lower.indexOf("</script", tagEnd);
    if (close < 0) break;
    if (lower.slice(open, tagEnd).includes("application/ld+json")) {
      try {
        blocks.push(JSON.parse(html.slice(tagEnd + 1, close).trim()));
      } catch {
        // Sites ship broken JSON-LD now and then; skip that block, try the others.
      }
    }
    from = close + 8;
  }
  return blocks;
}

type Node = Record<string, unknown>;

const isNode = (value: unknown): value is Node => typeof value === "object" && value !== null && !Array.isArray(value);

function isRecipe(node: Node): boolean {
  const type = node["@type"];
  return type === "Recipe" || (Array.isArray(type) && type.includes("Recipe"));
}

// Recipes sit at the top, in an array, or in an @graph; a few levels is enough for real sites.
function findRecipe(value: unknown, depth = 0): Node | null {
  if (depth > 4) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findRecipe(item, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (!isNode(value)) return null;
  if (isRecipe(value)) return value;
  return findRecipe(value["@graph"], depth + 1) ?? findRecipe(value["mainEntity"], depth + 1);
}

function toRecipe(node: Node): Recipe | null {
  const name = text(node.name);
  if (!name) return null;
  return {
    name: clip(name, 200),
    servings: servings(node.recipeYield),
    ingredients: strings(node.recipeIngredient ?? node.ingredients).slice(0, maxIngredients),
    steps: steps(node.recipeInstructions).slice(0, maxSteps),
    imageURL: image(node.image),
  };
}

// Servings only: "4", "4 servings", "Serves 6". A yield of things ("1 (9-inch) pie", "24 cookies") isn't people, so
// it's left out rather than scaling a pie for four into four pies.
function servings(value: unknown): number | null {
  const first = Array.isArray(value) ? value[0] : value;
  if (typeof first === "number") return Number.isInteger(first) && first >= 1 && first <= 100 ? first : null;
  const text = String(first ?? "").trim().toLowerCase();
  const match = text.match(
    /^(?:serves\s+|makes\s+)?(\d+)(?:\s*(?:-|to)\s*\d+)?\s*(servings?|people|persons?|portions?)?$/,
  );
  if (!match) return null;
  const number = Number(match[1]);
  return number >= 1 && number <= 100 ? number : null;
}

function strings(value: unknown): string[] {
  const list = Array.isArray(value) ? value : [value];
  return list.map((item) => text(item)).filter((line): line is string => line !== null);
}

// A string (one step per line), a list of strings, HowToStep objects, or HowToSection objects holding steps.
function steps(value: unknown, depth = 0): string[] {
  if (depth > 6) return [];
  if (typeof value === "string") {
    return value.split(/\r?\n/).map((line) => text(line, maxStep)).filter((line): line is string => line !== null);
  }
  if (Array.isArray(value)) return value.flatMap((item) => steps(item, depth + 1));
  if (!isNode(value)) return [];
  if (value.itemListElement !== undefined) return steps(value.itemListElement, depth + 1);
  const step = text(value.text ?? value.name, maxStep);
  return step ? [step] : [];
}

function image(value: unknown): string | null {
  const first = Array.isArray(value) ? value[0] : value;
  const url = typeof first === "string" ? first : isNode(first) ? first.url : null;
  return typeof url === "string" && /^https:\/\//i.test(url) ? url : null;
}

const entities: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  rsquo: "\u2019",
  lsquo: "\u2018",
  rdquo: "\u201d",
  ldquo: "\u201c",
  ndash: "\u2013",
  mdash: "\u2014",
  hellip: "\u2026",
  frac12: "½",
  frac14: "¼",
  frac34: "¾",
  frac13: "⅓",
  frac23: "⅔",
  frac18: "⅛",
  deg: "°",
  times: "×",
  eacute: "é",
  egrave: "è",
  ntilde: "ñ",
  uuml: "ü",
  ouml: "ö",
  auml: "ä",
  ccedil: "ç",
};

// Decoded twice, because some sites encode twice ("&amp;#39;").
export function decodeEntities(value: string): string {
  return decodeOnce(decodeOnce(value));
}

function decodeOnce(value: string): string {
  return value.replace(/&(#x[0-9a-f]+|#\d+|[a-z0-9]+);/gi, (match, entity: string) => {
    if (entity[0] === "#") {
      const code = entity[1].toLowerCase() === "x" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : match;
    }
    return entities[entity.toLowerCase()] ?? match;
  });
}

// Cut by code point, so an emoji at the edge is never split into half a surrogate pair (invalid JSON for the app).
function clip(value: string, limit: number): string {
  const points = Array.from(value);
  return points.length > limit ? points.slice(0, limit).join("") : value;
}

// Plain text: tags stripped, entities decoded, whitespace collapsed, capped. Empty is null.
function text(value: unknown, limit = maxLine): string | null {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const plain = decodeEntities(String(value).replace(/<[^>]{0,2000}>/g, " ")).replace(/\s+/g, " ").trim();
  return plain ? clip(plain, limit) : null;
}

// og:title, else <title>, from the head only. Each attribute is matched with its own closing quote, so an
// apostrophe inside double quotes ("Grandma's Pot Roast") stays in the title.
function pageTitle(html: string): string | null {
  const head = html.slice(0, headBytes);
  const metas = head.match(/<meta\b[^>]{0,2000}>/gi) ?? [];
  const og = metas.find((tag) => /property\s*=\s*(["'])og:title\1/i.test(tag))
    ?.match(/content\s*=\s*(["'])(.*?)\1/i)?.[2];
  const lower = head.toLowerCase();
  const open = lower.indexOf("<title");
  const start = open < 0 ? -1 : lower.indexOf(">", open);
  const end = start < 0 ? -1 : lower.indexOf("</title", start);
  const title = og ?? (end > start && start >= 0 ? head.slice(start + 1, end) : undefined);
  const plain = text(title, 200);
  return plain;
}

// og:description, else description. Line breaks are kept: a caption's list only reads as a list with them.
function pageCaption(html: string): string | null {
  const metas = html.slice(0, headBytes).match(/<meta\b[^>]{0,8000}>/gi) ?? [];
  const content = (name: RegExp) =>
    metas.find((tag) => name.test(tag))?.match(/content\s*=\s*(["'])(.*?)\1/is)?.[2];
  const raw = content(/property\s*=\s*(["'])og:description\1/i) ?? content(/name\s*=\s*(["'])description\1/i);
  if (!raw) return null;
  const plain = decodeEntities(raw.replace(/<[^>]{0,2000}>/g, " "))
    .split(/\r?\n/).map((line) => line.replace(/\s+/g, " ").trim()).filter((line) => line).join("\n");
  return plain || null;
}

// Whole lines only: half an ingredient would read as a different one.
function fitCaption(caption: string): string {
  if (caption.length <= maxCaption) return caption;
  const cut = clip(caption, maxCaption);
  const lastBreak = cut.lastIndexOf("\n");
  return lastBreak > 0 ? cut.slice(0, lastBreak) : cut;
}
