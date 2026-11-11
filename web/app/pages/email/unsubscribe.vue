<script setup lang="ts">
import { accountEmailEndpoint, type OptInEmail, unsubscribeEmail, unsubscribeKind } from "~/utils/email";
import type { ActionResult } from "~/utils/waitlist";

// An opt-in email's unsubscribe link lands here and does nothing until the button is pressed (mail scanners open links).
useSeoMeta({ title: "Unsubscribe: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const { public: config } = useRuntimeConfig();
const route = useRoute();
const signed = computed(() => (typeof route.query.u === "string" ? route.query.u : ""));
const kind = computed(() => unsubscribeKind(signed.value));
const working = ref(false);
const failed = ref<ActionResult | null>(null);

const what: Record<OptInEmail, { name: string; button: string }> = {
  weekly_plan: { name: "the weekly plan email", button: "Turn off the weekly email" },
  founding_updates: { name: "founding-family updates", button: "Unsubscribe from updates" },
};

async function unsubscribe() {
  working.value = true;
  const result = await unsubscribeEmail(accountEmailEndpoint(config.waitlistUrl), signed.value);
  working.value = false;
  if (result === "done") return navigateTo(`/email/unsubscribed?k=${kind.value}`);
  failed.value = result;
}
</script>

<template>
  <StatusCard heading="Unsubscribe">
    <template #default>
      <template v-if="kind">
        <p>This turns off {{ what[kind].name }} for your Foon account. Foon's other emails about your account still come.</p>
        <p>You can turn it back on anytime in Foon: Family, then Email.</p>
        <p v-if="failed === 'expired'" class="message problem" role="alert">
          This link didn't work. Turn the email off in Foon instead (Family, then Email), or write to us and we'll do it.
        </p>
        <p v-else-if="failed" class="message problem" role="alert">Something went wrong. Please try again in a few minutes.</p>
      </template>
      <p v-else>This link is missing something. Open it again from the email, or turn the email off in Foon (Family, then Email).</p>
    </template>
    <template v-if="kind" #actions>
      <button class="button" type="button" :disabled="working" @click="unsubscribe">
        {{ working ? "Turning it off..." : what[kind].button }}
      </button>
    </template>
  </StatusCard>
</template>
