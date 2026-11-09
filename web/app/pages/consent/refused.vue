<script setup lang="ts">
useSeoMeta({ title: "No invite: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const name = useConsentName();
// A renewal's No keeps the kid signed out and deletes nothing (Chris, 2026-11-09); withdrawing is separate.
const renewing = useConsentRenewal();
</script>

<template>
  <StatusCard heading="Got it">
    <template v-if="renewing">
      <p v-if="name">{{ name }} stays signed out of Foon. Nothing is deleted.</p>
      <p v-else>Your kid stays signed out of Foon. Nothing is deleted.</p>
      <p>
        If you change your mind, you can agree from their profile in Foon. To end your consent instead, open Family,
        then {{ name || "your kid" }}, then Withdraw consent.
      </p>
    </template>
    <template v-else>
      <p v-if="name">{{ name }} won't be invited, and Foon won't collect anything from them.</p>
      <p v-else>Your kid won't be invited, and Foon won't collect anything from them.</p>
      <p>If you change your mind, you can ask again from their profile in Foon.</p>
    </template>
  </StatusCard>
</template>
