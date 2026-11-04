<script setup lang="ts">
defineProps<{ heading: string }>();
</script>

<template>
  <section class="narrow section">
    <div class="card">
      <h1>{{ heading }}</h1>
      <slot />
      <NuxtLink class="button" to="/">Back to Foon</NuxtLink>
    </div>
  </section>
</template>
