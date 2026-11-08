<script setup lang="ts">
useSeoMeta({ title: "Already agreed: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// Another parent in the household gave consent first, so this link has nothing left to do. No email goes out from it.
const name = useConsentName();
</script>

<template>
  <StatusCard heading="Already agreed">
    <p v-if="name">Another parent in your family already agreed that {{ name }} can use Foon. You don't need to do anything.</p>
    <p v-else>Another parent in your family already agreed. You don't need to do anything.</p>
    <p v-if="name">You can invite {{ name }}: in Foon, open Family, then {{ name }}, then Invite.</p>
    <p v-else>You can invite your kid: in Foon, open Family, then your kid, then Invite.</p>
  </StatusCard>
</template>
