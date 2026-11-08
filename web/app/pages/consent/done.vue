<script setup lang="ts">
useSeoMeta({ title: "Thanks for agreeing: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// The name is there only when the parent came from /consent in this tab; the page reads fine without it.
const name = useConsentName();
</script>

<template>
  <StatusCard heading="Thanks, you're all set">
    <p>We've emailed you a confirmation, with a link to withdraw your consent if you change your mind.</p>
    <p v-if="name">You can invite {{ name }} now: in Foon, open Family, then {{ name }}, then Invite.</p>
    <p v-else>You can invite your kid now: in Foon, open Family, then your kid, then Invite.</p>
  </StatusCard>
</template>
