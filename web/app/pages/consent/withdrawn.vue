<script setup lang="ts">
useSeoMeta({ title: "Consent withdrawn: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const name = useConsentName();
</script>

<template>
  <StatusCard heading="Consent withdrawn">
    <p v-if="name">{{ name }} is signed out of Foon, and any invite is cancelled.</p>
    <p v-else>Your kid is signed out of Foon, and any invite is cancelled.</p>
    <p>Their profile stays in your family. To give consent again, open their profile in Foon.</p>
  </StatusCard>
</template>
