<script setup lang="ts">
import { SUPPORT_EMAIL } from "~/content";

useSeoMeta({ title: "Support: Foon", description: "How to reach Foon, and how to export or delete your family's data." });
</script>

<template>
  <article class="narrow prose section">
    <h1>Support</h1>
    <p>
      Write to <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>. Tell us what you were doing and what you
      expected, and which device you use.    </p>

    <h2>Your family's data</h2>
    <ul>
      <li>In the app, Family &rarr; Your data lets a planner or a parent export the household's data.</li>
      <li>
        The household's owner can delete the household there. It erases everything for everyone, right away, and keeps
        your account.
      </li>
      <li>
        Anyone can delete their own account from the same place. Deleting an account also deletes the household if you
        are its owner. Neither can be undone.
      </li>
      <li>
        A parent can delete everything about a kid from the kid's profile in Family. Their information and their sign-in
        account are deleted right away, and it can't be undone.
      </li>
      <li>If you can't get into the app, write to us and we'll help.</li>
    </ul>

    <h2>The waitlist</h2>
    <p>
      To leave, use the unsubscribe link in any waitlist email, or write to us and we'll remove you.
    </p>

    <h2>Subscriptions</h2>
    <p>
      Subscriptions are handled by Apple. You can manage or cancel one in your Apple Account settings, under
      Subscriptions.
    </p>
  </article>
</template>
