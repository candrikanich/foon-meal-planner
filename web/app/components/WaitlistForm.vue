<script setup lang="ts">
import { submitWaitlist, type WaitlistResult } from "~/utils/waitlist";

const { public: config } = useRuntimeConfig();

const email = ref("");
const firstName = ref("");
const website = ref("");
const sending = ref(false);
const result = ref<WaitlistResult | null>(null);
const status = ref<HTMLElement | null>(null);

const problems: Record<Exclude<WaitlistResult, "ok">, string> = {
  invalid: "Could you check your email address? If you gave a first name, it can use letters, spaces, hyphens and apostrophes.",
  slow_down: "That's a lot of tries from one place. Please wait a little and try again.",
  error: "Something went wrong on our side. Please try again in a few minutes.",
  unavailable: "The waitlist isn't open on this preview of the site.",
};

const message = computed(() => {
  if (!result.value) return "";
  return result.value === "ok"
    ? `Almost done. If ${email.value.trim()} can join, a note is on its way. Open it and tap the link to confirm your spot.`
    : problems[result.value];
});

async function onSubmit() {
  sending.value = true;
  result.value = await submitWaitlist(config.waitlistUrl, {
    email: email.value,
    firstName: firstName.value,
    website: website.value,
  });
  sending.value = false;
  // The message is in an always-present live region, so it's announced; focus moves there so it isn't lost when the fields go.
  await nextTick();
  status.value?.focus();
}
</script>

<template>
  <form class="waitlist" novalidate @submit.prevent="onSubmit">
    <div ref="status" role="status" aria-live="polite" tabindex="-1" class="status">
      <p v-if="message" class="message" :class="result === 'ok' ? 'ok' : 'problem'">{{ message }}</p>
    </div>
    <template v-if="result !== 'ok'">
      <div class="field">
        <label for="waitlist-email">Email <span class="hint">(grown-ups only, please)</span></label>
        <input id="waitlist-email" v-model="email" type="email" name="email" autocomplete="email" required inputmode="email">
      </div>
      <div class="field">
        <label for="waitlist-name">First name <span class="hint">(optional)</span></label>
        <input id="waitlist-name" v-model="firstName" type="text" name="firstName" autocomplete="given-name" maxlength="40">
      </div>
      <div class="honey" aria-hidden="true">
        <label for="waitlist-website">Leave this empty</label>
        <input id="waitlist-website" v-model="website" type="text" name="website" tabindex="-1" autocomplete="off">
      </div>
      <button class="button" type="submit" :disabled="sending">
        {{ sending ? "Sending..." : "Save my family's spot" }}
      </button>
      <p class="fineprint">
        We use your email only to confirm your spot and tell you when Foon opens. Unsubscribe any time and your address is deleted.
        <NuxtLink to="/privacy">How we handle it</NuxtLink>.
      </p>
    </template>
  </form>
</template>
