<script setup lang="ts">
import { inviteCode } from "~/utils/invite";

// Foon QA's invite link (docs/foon-qa.md) opens Foon QA, the staging test app, when it's installed. Without it, the link
// lands here. Only testers get these, so the page says it's the test app and doesn't link the App Store.
useSeoMeta({ title: "You're invited to Foon QA", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// A prerendered page hydrates on its query-less route and gets ?code= only once Nuxt is ready, so this updates then.
const route = useRoute();
const code = computed(() => inviteCode(route.query.code));
</script>

<template>
  <StatusCard heading="You're invited to Foon QA">
    <p>
      Foon QA is the test version of Foon, with its own test households. It doesn't share anything with the Foon app your
      family uses. To join this test household:
    </p>
    <ol>
      <li>Install Foon QA from TestFlight on your iPhone or iPad. Ask whoever invited you to add you as a tester.</li>
      <li>Open Foon QA and sign in with Apple.</li>
      <li v-if="code">
        Under Joining a family?, enter <strong class="invite-code">{{ code }}</strong> and tap Join family.
      </li>
      <li v-else>Under Joining a family?, enter the code from your invite message and tap Join family.</li>
    </ol>
    <p>If Foon QA is already installed, open this link again from Messages and it opens Foon QA.</p>
  </StatusCard>
</template>
