<script setup lang="ts">
import { SUPPORT_EMAIL } from "~/content";
</script>

<template>
  <a class="skip" href="#main">Skip to content</a>
  <header class="site-header">
    <div class="wrap">
      <NuxtLink class="brand" to="/">
        <img src="/favicon.png" alt="" width="32" height="32">
        Foon
      </NuxtLink>
      <nav aria-label="Main">
        <NuxtLink to="/#waitlist">Join the waitlist</NuxtLink>
        <NuxtLink to="/support">Support</NuxtLink>
      </nav>
    </div>
  </header>
  <main id="main" tabindex="-1">
    <NuxtPage />
  </main>
  <footer class="site-footer">
    <div class="wrap">
      <span>&copy; 2026 The Recruiting Compass LLC</span>
      <nav aria-label="Footer">
        <NuxtLink to="/privacy">Privacy</NuxtLink> &middot;
        <NuxtLink to="/terms">Terms</NuxtLink> &middot;
        <NuxtLink to="/support">Support</NuxtLink> &middot;
        <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>
      </nav>
    </div>
  </footer>
</template>
