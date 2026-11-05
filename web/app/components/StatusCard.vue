<script setup lang="ts">
defineProps<{ heading: string }>();
</script>

<template>
  <section class="narrow section">
    <div class="card">
      <h1>{{ heading }}</h1>
      <slot />
      <!-- When the page has its own action (confirm, delete), that's the one button that stands out. -->
      <div class="actions">
        <slot name="actions" />
        <NuxtLink class="button" :class="{ secondary: $slots.actions }" to="/">Back to Foon</NuxtLink>
      </div>
    </div>
  </section>
</template>
