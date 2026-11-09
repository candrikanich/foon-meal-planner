<script setup lang="ts">
import { SUPPORT_EMAIL, TERMS_VERSION } from "~/content";

useSeoMeta({ title: "Terms: Foon", description: "Foon's terms of use are being finalised and will be published before launch." });
</script>

<template>
  <article class="narrow prose section">
    <h1>Terms</h1>
    <p class="fineprint">Version {{ TERMS_VERSION }}</p>
    <p class="draft">
      Foon's full terms of use are being finalised. They will be published here, and shown in the app, before Foon opens
      to everyone.
    </p>
    <p>
      Until then: joining the waitlist is free and doesn't commit you to anything. The founding-family offer (free during
      the beta, then half price on the annual plan, locked for life) is our plan for the first 50 families. The final
      details will be in the full terms.
    </p>
    <p>
      Foon is published by The Recruiting Compass LLC. Questions:
      <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>.
    </p>
  </article>
</template>
