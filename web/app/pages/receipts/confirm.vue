<script setup lang="ts">
import { confirmReceiptSender, type ReceiptConfirmResult, receiptInboxEndpoint } from "~/utils/receipts";

// The link in the email lands here and does nothing until the button is pressed (mail scanners open links).
useSeoMeta({ title: "Confirm your address: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const { public: config } = useRuntimeConfig();
const route = useRoute();
const token = computed(() => (typeof route.query.t === "string" ? route.query.t : ""));
const working = ref(false);
const result = ref<ReceiptConfirmResult | null>(null);

const headings: Record<ReceiptConfirmResult, string> = {
  confirmed: "You're all set",
  expired: "This link has expired",
  unknown: "That link didn't work",
  error: "Confirm your address",
};
const heading = computed(() => (result.value ? headings[result.value] : "Confirm your address"));

async function confirm() {
  working.value = true;
  result.value = await confirmReceiptSender(receiptInboxEndpoint(config.receiptInboxUrl, config.waitlistUrl), token.value);
  working.value = false;
}
</script>

<template>
  <StatusCard :heading="heading">
    <template #default>
      <p v-if="result === 'confirmed'">Receipts you forward from this address now go to your family's Foon.</p>
      <p v-else-if="result === 'expired'">Add the address again in Foon to get a new one.</p>
      <p v-else-if="result === 'unknown'">
        It may have been used already, or replaced by a newer one. If the address isn't confirmed in Foon yet, add it again
        to get a new link.
      </p>
      <template v-else-if="token">
        <p>Tap the button to confirm this address, so receipts you forward from it go to your family's Foon.</p>
        <p v-if="result === 'error'" class="message problem" role="alert">Something went wrong. Please try again in a few minutes.</p>
      </template>
      <p v-else>This link is missing something. Open it again from the email, or add the address again in Foon.</p>
    </template>
    <template v-if="token && (result === null || result === 'error')" #actions>
      <button class="button" type="button" :disabled="working" @click="confirm">
        {{ working ? "Confirming..." : "Confirm my address" }}
      </button>
    </template>
  </StatusCard>
</template>
