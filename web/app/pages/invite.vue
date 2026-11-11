<script setup lang="ts">
import { APP_STORE_URL } from "~/content";
import { inviteCode } from "~/utils/invite";

// An invite link (#85) opens Foon when it's installed. Without Foon, the link lands here, and the code is how to join
// after installing: iOS doesn't carry a link through an install.
useSeoMeta({ title: "You're invited to Foon", robots: "noindex" });
useHead({ meta: [{ name: "referrer", content: "no-referrer" }] });

// A prerendered page hydrates on its query-less route and gets ?code= only once Nuxt is ready, so this updates then.
const route = useRoute();
const code = computed(() => inviteCode(route.query.code));
</script>

<template>
  <StatusCard heading="You're invited to Foon">
    <p>Foon is your family's dinner planner. To join them:</p>
    <ol>
      <li>
        <template v-if="APP_STORE_URL">
          Get <a :href="APP_STORE_URL">Foon from the App Store</a> on your iPhone or iPad.
        </template>
        <template v-else>
          Install Foon on your iPhone or iPad. It's in testing for now, so ask whoever invited you to add you in
          TestFlight.
        </template>
      </li>
      <li>Open Foon and sign in with Apple.</li>
      <li v-if="code">
        Under Joining a family?, enter <strong class="invite-code">{{ code }}</strong> and tap Join family.
      </li>
      <li v-else>Under Joining a family?, enter the code from your invite message and tap Join family.</li>
    </ol>
    <p>If Foon is already installed, open this link again from Messages and it opens Foon.</p>
  </StatusCard>
</template>
