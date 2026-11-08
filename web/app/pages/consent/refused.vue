<script setup lang="ts">
useSeoMeta({ title: "No invite: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const name = useConsentName();
</script>

<template>
  <StatusCard heading="Got it">
    <p v-if="name">{{ name }} won't be invited, and Foon won't collect anything from them.</p>
    <p v-else>Your kid won't be invited, and Foon won't collect anything from them.</p>
    <p>If you change your mind, you can ask again from their profile in Foon.</p>
  </StatusCard>
</template>
