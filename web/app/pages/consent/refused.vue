<script setup lang="ts">
import { renewalWords } from "~/utils/consent";

useSeoMeta({ title: "No invite: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const name = useConsentName();
// A renewal's No keeps the kid signed out and deletes nothing (Chris, 2026-11-09); withdrawing is separate.
const renewing = useConsentRenewal();
const wasLinked = useConsentWasLinked();
</script>

<template>
  <StatusCard heading="Got it">
    <template v-if="renewing">
      <p>{{ renewalWords(name, wasLinked).refused }}</p>
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
