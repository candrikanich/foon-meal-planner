<script setup lang="ts">
import { confirmSignup, type ActionResult } from "~/utils/waitlist";

// The link in the email lands here and does nothing until the button is pressed (mail scanners open links).
useSeoMeta({ title: "Confirm your email: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const { public: config } = useRuntimeConfig();
const route = useRoute();
const token = computed(() => (typeof route.query.t === "string" ? route.query.t : ""));
const working = ref(false);
const failed = ref<ActionResult | null>(null);

async function confirm() {
  working.value = true;
  const result = await confirmSignup(config.waitlistUrl, token.value);
  working.value = false;
  if (result === "done") return navigateTo("/waitlist/confirmed");
  if (result === "expired") return navigateTo("/waitlist/expired");
  failed.value = result;
}
</script>

<template>
  <StatusCard heading="Confirm your email">
    <template #default>
      <template v-if="token">
        <p>One last step: tap the button to confirm your spot on the founding-family waitlist.</p>
        <p v-if="failed" class="message problem" role="alert">Something went wrong. Please try again in a few minutes.</p>
      </template>
      <p v-else>This link is missing something. Open it again from the email, or sign up again on the home page.</p>
    </template>
    <template v-if="token" #actions>
      <button class="button" type="button" :disabled="working" @click="confirm">
        {{ working ? "Confirming..." : "Confirm my email" }}
      </button>
    </template>
  </StatusCard>
</template>
