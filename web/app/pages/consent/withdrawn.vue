<script setup lang="ts">
useSeoMeta({ title: "Consent withdrawn: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// Reached from the withdraw link, and from an old consent link whose consent was since withdrawn.
const name = useConsentName();
</script>

<template>
  <StatusCard heading="Consent withdrawn">
    <p v-if="name">Consent for {{ name }} is withdrawn. They can't sign in to Foon, and any invite is cancelled.</p>
    <p v-else>Consent for your kid is withdrawn. They can't sign in to Foon, and any invite is cancelled.</p>
    <p v-if="name">Their profile stays in your family. To agree again, ask from Foon: open Family, then {{ name }}.</p>
    <p v-else>Their profile stays in your family. To agree again, ask from Foon: open Family, then your kid.</p>
  </StatusCard>
</template>
