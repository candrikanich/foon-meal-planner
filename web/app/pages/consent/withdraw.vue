<script setup lang="ts">
import { answerWithdraw, nextPage, type PageState, type WithdrawDecision } from "~/utils/consent";

// The link in email 2 lands here. Opening it only looks the consent up (mail scanners open links); the button withdraws.
useSeoMeta({ title: "Withdraw consent: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const { public: config } = useRuntimeConfig();
const route = useRoute();
const token = computed(() => (typeof route.query.t === "string" ? route.query.t : ""));
const name = useConsentName();
const state = ref<PageState>({ view: "loading" });
const working = ref<WithdrawDecision | null>(null);

async function send(decision: WithdrawDecision) {
  working.value = decision;
  const move = nextPage(state.value, await answerWithdraw(config.consentUrl, token.value, decision));
  working.value = null;
  if ("navigate" in move) return navigateTo(move.navigate, { replace: true });
  state.value = move.state;
  if (move.state.view === "ask") name.value = move.state.firstName;
}

// Not onMounted: a prerendered page hydrates on its query-less route and gets ?t= only once Nuxt is ready.
onNuxtReady(() => send("lookup"));
</script>

<template>
  <StatusCard v-if="state.view === 'ask'" heading="Withdraw consent">
    <template #default>
      <p>
        This stops {{ state.firstName }}'s Foon account. They're signed out at once, and any invite is cancelled. If you
        don't give consent again within 30 days, what {{ state.firstName }} added themselves is deleted.
      </p>
      <p>Their profile stays in your family, and you can invite them again from Foon later.</p>
      <p v-if="state.notice !== 'none'" class="message problem" role="alert">
        Something went wrong. Please try again in a few minutes.
      </p>
    </template>
    <template #actions>
      <button class="button" type="button" :disabled="working !== null" @click="send('withdraw')">
        {{ working === "withdraw" ? "Withdrawing..." : "Withdraw consent" }}
      </button>
    </template>
  </StatusCard>
  <StatusCard v-else-if="state.view === 'unreachable'" heading="We couldn't open this">
    <template #default>
      <p>
        Check your connection and try again. You can also withdraw in Foon: open Family, then your kid, then Withdraw
        consent.
      </p>
    </template>
    <template #actions>
      <button class="button" type="button" :disabled="working !== null" @click="send('lookup')">
        {{ working ? "Loading..." : "Try again" }}
      </button>
    </template>
  </StatusCard>
  <StatusCard v-else heading="Withdraw consent">
    <p role="status">Loading...</p>
  </StatusCard>
</template>
