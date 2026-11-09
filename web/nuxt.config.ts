// A static marketing site: every page is prerendered. The waitlist form talks to the Supabase `waitlist` Edge Function,
// and the parental consent pages to `parental-consent`.

// The site's types leave out Node's, and the config only needs to read the build's environment.
const buildEnv = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env ?? {};

export default defineNuxtConfig({
  compatibilityDate: "2026-11-01",
  devtools: { enabled: false },
  telemetry: false,
  typescript: { strict: true },
  css: ["~/assets/css/foon.css"],
  routeRules: { "/**": { prerender: true } },
  modules: [
    // The function URLs are baked into the prerendered pages. Built without one, the site ships and its forms fail only
    // when someone uses them (the consent link, 2026-11-08), so a build without both stops here instead.
    (_options, nuxt) => {
      if (nuxt.options.dev || nuxt.options._prepare) return;
      const missing = ["NUXT_PUBLIC_WAITLIST_URL", "NUXT_PUBLIC_CONSENT_URL"].filter((name) => !buildEnv[name]);
      if (missing.length > 0) {
        throw new Error(`Set ${missing.join(" and ")} before building (see .env.example).`);
      }
    },
  ],
  runtimeConfig: {
    public: {
      // NUXT_PUBLIC_WAITLIST_URL: https://<project-ref>.supabase.co/functions/v1/waitlist (read at build time).
      waitlistUrl: "",
      // NUXT_PUBLIC_CONSENT_URL: https://<project-ref>.supabase.co/functions/v1/parental-consent (read at build time).
      consentUrl: "",
      // NUXT_PUBLIC_SITE_URL: the canonical origin, for Open Graph and canonical links.
      siteUrl: "https://getfoon.com",
    },
  },
  app: {
    head: {
      htmlAttrs: { lang: "en" },
      meta: [
        { name: "viewport", content: "width=device-width, initial-scale=1" },
        { name: "theme-color", content: "#FBF5EC", media: "(prefers-color-scheme: light)" },
        { name: "theme-color", content: "#1C1814", media: "(prefers-color-scheme: dark)" },
      ],
      link: [
        { rel: "icon", type: "image/png", href: "/favicon.png" },
        { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
      ],
    },
  },
});
