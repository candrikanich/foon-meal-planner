// A static marketing site: every page is prerendered. The waitlist form talks to the Supabase `waitlist` Edge Function,
// and the parental consent pages to `parental-consent`.
export default defineNuxtConfig({
  compatibilityDate: "2026-11-01",
  devtools: { enabled: false },
  telemetry: false,
  typescript: { strict: true },
  css: ["~/assets/css/foon.css"],
  routeRules: { "/**": { prerender: true } },
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
