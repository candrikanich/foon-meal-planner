<script setup lang="ts">
import { unsubscribeSignup, type ActionResult } from "~/utils/waitlist";

// The link in the email lands here and does nothing until the button is pressed (mail scanners open links).
useSeoMeta({ title: "Unsubscribe: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const { public: config } = useRuntimeConfig();
const route = useRoute();
const signed = computed(() => (typeof route.query.u === "string" ? route.query.u : ""));
const working = ref(false);
const failed = ref<ActionResult | null>(null);

async function unsubscribe() {
  working.value = true;
  const result = await unsubscribeSignup(config.waitlistUrl, signed.value);
  working.value = false;
  if (result === "done") return navigateTo("/waitlist/unsubscribed");
  if (result === "expired") return navigateTo("/waitlist/expired");
  failed.value = result;
}
</script>

<template>
  <StatusCard heading="Unsubscribe">
    <template #default>
      <template v-if="signed">
        <p>This deletes your email address and name from the waitlist right away, and we won't write again.</p>
        <p v-if="failed" class="message problem" role="alert">Something went wrong. Please try again in a few minutes.</p>
      </template>
      <p v-else>This link is missing something. Open it again from the email, or write to us and we'll remove you.</p>
    </template>
    <template v-if="signed" #actions>
      <button class="button" type="button" :disabled="working" @click="unsubscribe">
        {{ working ? "Removing..." : "Delete my address" }}
      </button>
    </template>
  </StatusCard>
</template>
