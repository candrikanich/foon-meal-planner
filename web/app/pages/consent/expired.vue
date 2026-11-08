<script setup lang="ts">
useSeoMeta({ title: "That link didn't work: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// ?link=withdraw is email 2's withdraw link; otherwise it's email 1's consent link. A prerendered page hydrates on its
// query-less route and gets the query only once Nuxt is ready, so this updates then.
const route = useRoute();
const withdrawLink = computed(() => route.query.link === "withdraw");
</script>

<template>
  <StatusCard heading="That link didn't work">
    <p v-if="withdrawLink">
      This link has expired. You can still withdraw in Foon: open Family, then your kid, then Withdraw consent.
    </p>
    <p v-else>
      It may be more than 7 days old, replaced by a newer email, or your kid's profile may have changed. Open their
      profile in Foon to see where things stand, and send a new email if you need to.
    </p>
  </StatusCard>
</template>
