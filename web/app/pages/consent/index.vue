<script setup lang="ts">
import { consentKept } from "~/content";
import { answerConsent, nextPage, type ConsentDecision, type PageState } from "~/utils/consent";

// The link in email 1 lands here. Opening it only looks the request up (mail scanners open links); the buttons decide.
useSeoMeta({ title: "Your consent: Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

const { public: config } = useRuntimeConfig();
const route = useRoute();
const token = computed(() => (typeof route.query.t === "string" ? route.query.t : ""));
const name = useConsentName();
const state = ref<PageState>({ view: "loading" });
const working = ref<ConsentDecision | null>(null);

async function send(decision: ConsentDecision) {
  working.value = decision;
  const move = nextPage(state.value, await answerConsent(config.consentUrl, token.value, decision));
  working.value = null;
  if ("navigate" in move) return navigateTo(move.navigate, { replace: true });
  state.value = move.state;
  if (move.state.view === "ask") name.value = move.state.firstName;
}

// Not onMounted: a prerendered page hydrates on its query-less route and gets ?t= only once Nuxt is ready.
onNuxtReady(() => send("lookup"));
</script>

<template>
  <StatusCard v-if="state.view === 'ask'" :heading="`Can ${state.firstName} use Foon?`">
    <template #default>
      <p>
        You asked to invite {{ state.firstName }} to Foon, so they can use it on their own device. Foon needs a parent's
        consent first.
      </p>
      <p>If you agree, Foon keeps:</p>
      <ul>
        <li v-for="item in consentKept(state.firstName)" :key="item">{{ item }}</li>
      </ul>
      <p>
        It's used only to run Foon for your family, and everyone in your household can see it. We don't disclose it to
        anyone else. Only the services that run Foon for us handle it (Supabase hosts it; Apple delivers notifications).
        It's never sold or used for ads.
      </p>
      <p>If you say no, Foon collects nothing from {{ state.firstName }}, and they can't sign in.</p>
      <p>
        You can withdraw your consent any time: in Foon, open Family, then {{ state.firstName }}, then Withdraw consent.
        Read our <NuxtLink to="/privacy">privacy policy</NuxtLink>.
      </p>
      <p v-if="state.notice === 'again'" class="message problem" role="alert">Almost done, tap again.</p>
      <p v-else-if="state.notice === 'problem'" class="message problem" role="alert">
        Something went wrong. Please try again in a few minutes.
      </p>
    </template>
    <template #actions>
      <button class="button" type="button" :disabled="working !== null" @click="send('agree')">
        {{ working === "agree" ? "Saving..." : "I agree" }}
      </button>
      <button class="button secondary" type="button" :disabled="working !== null" @click="send('refuse')">
        {{ working === "refuse" ? "Saving..." : `No, don't invite ${state.firstName}` }}
      </button>
    </template>
  </StatusCard>
  <StatusCard v-else-if="state.view === 'unreachable'" heading="We couldn't open this">
    <template #default>
      <p>Check your connection and try again. If it keeps happening, open the link from the email again later.</p>
    </template>
    <template #actions>
      <button class="button" type="button" :disabled="working !== null" @click="send('lookup')">
        {{ working ? "Loading..." : "Try again" }}
      </button>
    </template>
  </StatusCard>
  <StatusCard v-else heading="Your consent">
    <p role="status">Loading...</p>
  </StatusCard>
</template>
