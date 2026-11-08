<script setup lang="ts">
useSeoMeta({ title: "Consent withdrawn: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// Reached from the withdraw link, and from an old consent link whose consent was since withdrawn. Says only what
// happened to this link's consent: another parent may have agreed since, so the kid's current state isn't claimed.
const name = useConsentName();
</script>

<template>
  <StatusCard heading="Consent withdrawn">
    <p>The consent given from this link is withdrawn, and any invite it allowed is cancelled.</p>
    <p v-if="name">{{ name }}'s profile stays in your family. To see where things stand, or to agree again, open Foon: Family, then {{ name }}.</p>
    <p v-else>Their profile stays in your family. To see where things stand, or to agree again, open Foon: Family, then your kid.</p>
  </StatusCard>
</template>
