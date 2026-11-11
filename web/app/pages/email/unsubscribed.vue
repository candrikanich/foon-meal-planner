<script setup lang="ts">
useSeoMeta({ title: "Unsubscribed: Foon", robots: "noindex" });

const route = useRoute();
const name = computed(() =>
  route.query.k === "founding_updates" ? "founding-family updates" : route.query.k === "weekly_plan" ? "the weekly plan email" : "that email",
);
</script>

<template>
  <StatusCard heading="You're unsubscribed">
    <p>We've turned off {{ name }}. If that was a mistake, turn it back on anytime in Foon: Family, then Email.</p>
  </StatusCard>
</template>
