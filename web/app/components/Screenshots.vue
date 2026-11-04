<script setup lang="ts">
import { screenshots } from "~/content";

// Real images go in web/public/screenshots/ under the names in content.ts; any that exist replace their placeholder.
const available = new Set(
  Object.keys(import.meta.glob("/public/screenshots/*.{png,jpg,jpeg,webp}", { eager: false }))
    .map((path) => path.split("/").pop()),
);
</script>

<template>
  <ul class="shots">
    <li v-for="shot in screenshots" :key="shot.file">
      <figure class="shot">
        <div class="frame">
          <img v-if="available.has(shot.file)" :src="`/screenshots/${shot.file}`" :alt="shot.alt" loading="lazy">
          <span v-else>Screenshot coming soon</span>
        </div>
        <figcaption>{{ shot.caption }}</figcaption>
      </figure>
    </li>
  </ul>
</template>
