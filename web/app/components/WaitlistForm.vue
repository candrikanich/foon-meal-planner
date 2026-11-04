<script setup lang="ts">
import { submitWaitlist, type WaitlistResult } from "~/utils/waitlist";

const { public: config } = useRuntimeConfig();

const email = ref("");
const firstName = ref("");
const website = ref("");
const sending = ref(false);
const result = ref<WaitlistResult | null>(null);

const problems: Record<Exclude<WaitlistResult, "ok">, string> = {
  invalid: "That doesn't look like an email address. Could you check it?",
  slow_down: "That's a lot of tries from one place. Please wait a little and try again.",
  error: "Something went wrong on our side. Please try again in a few minutes.",
  unavailable: "The waitlist isn't open on this preview of the site.",
};

async function onSubmit() {
  sending.value = true;
  result.value = await submitWaitlist(config.waitlistUrl, {
    email: email.value,
    firstName: firstName.value,
    website: website.value,
  });
  sending.value = false;
}
</script>

<template>
  <form class="waitlist" novalidate @submit.prevent="onSubmit">
    <p v-if="result === 'ok'" class="message ok" role="status">
      Almost done. We sent a note to {{ email.trim() }}. Open it and tap the link to confirm your spot.
    </p>
    <template v-else>
      <div class="field">
        <label for="waitlist-email">Email <span class="hint">(grown-ups only, please)</span></label>
        <input id="waitlist-email" v-model="email" type="email" name="email" autocomplete="email" required inputmode="email">
      </div>
      <div class="field">
        <label for="waitlist-name">First name <span class="hint">(optional)</span></label>
        <input id="waitlist-name" v-model="firstName" type="text" name="firstName" autocomplete="given-name" maxlength="60">
      </div>
      <div class="honey" aria-hidden="true">
        <label for="waitlist-website">Leave this empty</label>
        <input id="waitlist-website" v-model="website" type="text" name="website" tabindex="-1" autocomplete="off">
      </div>
      <p v-if="result" class="message problem" role="alert">{{ problems[result] }}</p>
      <button class="button" type="submit" :disabled="sending">
        {{ sending ? "Sending..." : "Save my family's spot" }}
      </button>
      <p class="fineprint">
        We use your email only to confirm your spot and tell you when Foon opens. Unsubscribe any time.
        <NuxtLink to="/privacy">How we handle it</NuxtLink>.
      </p>
    </template>
  </form>
</template>
